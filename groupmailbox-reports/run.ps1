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
$mailboxes = Get-EXOMailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited -PropertySets All
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

    $mailboxProps = $mb | Select-Object -Property *
    $statProps    = $stat | Select-Object -Property *
 
    
    [PSCustomObject]@{
        Mailbox             = $mailboxProps
        Statistics          = $statProps
    }
}
 
 # Ergebnis nach Grösse absteigend sortieren und als CSV im HTTP-Response zurückgeben

$sortedReport = $report | Sort-Object -Property TotalItemSize_Bytes -Descending
$csvLines = $sortedReport | ConvertTo-Csv -NoTypeInformation
$csvBody = $csvLines -join "`n"

Write-Host "[groupmailbox-reports] CSV report generated. Rows: $($report.Count)"

$statPropertyNames = @()
if ($report.Count -gt 0) {
    $statPropertyNames = $report[0].PSObject.Properties.Name
}

Write-Host "[groupmailbox-reports] Cosmos DB output binding disabled."

$responseBody = [pscustomobject]@{
    generatedAt       = (Get-Date).ToString("o")
    groupMailboxCount = $groupMailboxCount
    csv               = $csvBody
    mailboxes         = $sortedReport
}

$headers = @{
    "Content-Type" = "application/json; charset=utf-8"
    "X-GroupMailbox-Count" = "$groupMailboxCount"
}

$resp = New-HttpResponse -StatusCode 200 -Body ($responseBody | ConvertTo-Json -Depth 10) -Headers $headers
Push-OutputBinding -Name Response -Value $resp

Write-Host "[groupmailbox-reports] Response sent."
 