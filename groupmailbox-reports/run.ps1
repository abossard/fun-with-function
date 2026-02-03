param($request)

# HTTP Response helper
function New-HttpResponse {
    param(
        [int]$StatusCode,
        [string]$Body,
        [hashtable]$Headers = @{}
    )
    return @{ StatusCode = $StatusCode; Body = $Body; Headers = $Headers }
}
Write-Host "[groupmailbox-reports] Starting function execution sooon."

Import-Module ExchangeOnlineManagement -ErrorAction Stop -Force

Write-Host "[groupmailbox-reports] Starting function execution."
 
Connect-ExchangeOnline `
  -ManagedIdentity `
  -Organization MngEnvMCAP462928.onmicrosoft.com `
  -ManagedIdentityAccountId 1126b55e-26ae-492e-8701-3e1b7af612b8

Write-Host "[groupmailbox-reports] Connected to Exchange Online."
 
# Hole alle Mailboxen vom Typ Shared und GroupMailbox
$mailboxes = Get-Mailbox -ResultSize 100
$groupMailboxCount = $mailboxes.Count

Write-Host "[groupmailbox-reports] Retrieved $groupMailboxCount shared mailboxes."

$mailboxIndex = 0
$report = foreach ($mb in $mailboxes) {
    $mailboxIndex++
    if ($mailboxIndex -eq 1 -or ($mailboxIndex % 25 -eq 0) -or ($mailboxIndex -eq $groupMailboxCount)) {
        Write-Host "[groupmailbox-reports] Processing mailbox ${mailboxIndex}/${groupMailboxCount}: $($mb.PrimarySmtpAddress)"
    }
    # Hole Statistiken
    $stat = Get-MailboxStatistics -Identity $mb.Identity
    $statJson = $stat | ConvertTo-Json -Depth 6
    $statObj = $statJson | ConvertFrom-Json

    # Quota-Werte aus Get-Mailbox
    $mbDetail = Get-Mailbox -Identity $mb.Identity

    # Quotas können 'Unlimited' oder Grössenwerte sein
    $issueWarningQuota = $mbDetail.IssueWarningQuota
    $prohibitSendQuota = $mbDetail.ProhibitSendQuota
    $prohibitSendReceiveQuota = $mbDetail.ProhibitSendReceiveQuota
 
    # Hilfsfunktion: parse Quota (liefert Bytes oder $null wenn Unlimited)
    function Parse-QuotaToBytes {
        param([string]$q)

        if (-not $q) { return $null }
        if ($q -eq 'Unlimited') { return $null }

        # Beispieleingaben: "100 GB", "20 MB (20,971,520 bytes)" oder "10.00 GB (10,737,418,240 bytes)"
        if ($q -match '\((\d[\d,]*) bytes\)') {
            $b = ($matches[1] -replace ',','')
            return [long]::Parse($b)
        }

        # Falls kein bytes-Teil, parsen wir einfache Einheiten
        if ($q -match '([\d\.,]+)\s*(KB|MB|GB|TB)') {
            $num = [double]($matches[1] -replace ',','')
            switch ($matches[2]) {
                'KB' { return [long]($num * 1KB) }
                'MB' { return [long]($num * 1MB) }
                'GB' { return [long]($num * 1GB) }
                'TB' { return [long]($num * 1TB) }
            }
        }        
        return $null

    }
 
    $warnBytes = Parse-QuotaToBytes $issueWarningQuota.ToString()

    $sendBytes = Parse-QuotaToBytes $prohibitSendQuota.ToString()

    $sendRecvBytes = Parse-QuotaToBytes $prohibitSendReceiveQuota.ToString()
 
    $statRow = [ordered]@{}
    foreach ($prop in $statObj.PSObject.Properties) {
        $statRow[$prop.Name] = $prop.Value
    }
    $statRow["GroupMailboxCount"] = $groupMailboxCount
    [PSCustomObject]$statRow

}
 
# Ergebnis nach Grösse absteigend sortieren und als CSV im HTTP-Response zurückgeben

$csvLines = $report | Sort-Object -Property TotalItemSize_Bytes -Descending | ConvertTo-Csv -NoTypeInformation
$csvBody = $csvLines -join "`n"

Write-Host "[groupmailbox-reports] CSV report generated. Rows: $($report.Count)"

$statPropertyNames = @()
if ($report.Count -gt 0) {
    $statPropertyNames = $report[0].PSObject.Properties.Name
}

$statsDoc = [pscustomobject]@{
    id                  = [guid]::NewGuid().ToString()
    pk                  = "groupmailbox-reports"
    generatedAt         = (Get-Date).ToString("o")
    groupMailboxCount   = $groupMailboxCount
    rowCount            = $report.Count
    statPropertyNames   = $statPropertyNames
}

Push-OutputBinding -Name cosmosDoc -Value $statsDoc
Write-Host "[groupmailbox-reports] Stats document sent to Cosmos DB."

$headers = @{
    "Content-Type" = "text/csv; charset=utf-8"
    "Content-Disposition" = "attachment; filename=GroupMailboxes_Quota.csv"
    "X-GroupMailbox-Count" = "$groupMailboxCount"
}

$resp = New-HttpResponse -StatusCode 200 -Body $csvBody -Headers $headers
Push-OutputBinding -Name Response -Value $resp

Write-Host "[groupmailbox-reports] Response sent."
 