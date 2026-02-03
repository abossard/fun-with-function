param($Request)

# HTTP Response helper
function New-HttpResponse {
    param(
        [int]$StatusCode,
        [string]$Body,
        [hashtable]$Headers = @{}
    )
    return @{ StatusCode = $StatusCode; Body = $Body; Headers = $Headers }
}

Import-Module ExchangeOnlineManagement -ErrorAction Stop -Force

$appId = $env:GRAPH_APP_CLIENT_ID
$certBase64 = $env:EXO_APP_PFX_BASE64
$certPassword = $env:EXO_APP_PFX_PASSWORD

if (-not $appId) {
    $resp = New-HttpResponse -StatusCode 500 -Body 'Missing app setting GRAPH_APP_CLIENT_ID.'
    Push-OutputBinding -Name Response -Value $resp
    return
}

if (-not $certBase64) {
    $resp = New-HttpResponse -StatusCode 500 -Body 'Missing app setting EXO_APP_PFX_BASE64.'
    Push-OutputBinding -Name Response -Value $resp
    return
}

if (-not $certPassword) {
    $resp = New-HttpResponse -StatusCode 500 -Body 'Missing app setting EXO_APP_PFX_PASSWORD.'
    Push-OutputBinding -Name Response -Value $resp
    return
}

try {
    $pfxBytes = [Convert]::FromBase64String($certBase64)
    $securePassword = ConvertTo-SecureString $certPassword -AsPlainText -Force
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $pfxBytes,
        $securePassword,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
    )
} catch {
    $resp = New-HttpResponse -StatusCode 500 -Body "Failed to load certificate: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value $resp
    return
}

Connect-ExchangeOnline `
  -AppId $appId `
  -Organization MngEnvMCAP462928.onmicrosoft.com `
  -Certificate $cert

# Hilfsfunktion: formatiere Bytes in lesbare Grössen

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { "{0:N2} TB" -f ($Bytes / 1TB) }
    elseif ($Bytes -ge 1GB) { "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { "{0:N2} KB" -f ($Bytes / 1KB) }
    else { "$Bytes Bytes" }
}

# Hole alle Mailboxen vom Typ Shared und GroupMailbox
$mailboxes = Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited

$report = foreach ($mb in $mailboxes) {
    # Hole Statistiken
    $stat = Get-MailboxStatistics -Identity $mb.Identity
    $totalBytes = $null
    if ($stat.TotalItemSize -is [string]) {
        if ($stat.TotalItemSize -match '\((\d[\d,]*) bytes\)') {
            $bytesStr = $matches[1] -replace ',', ''
            [long]$totalBytes = [long]::Parse($bytesStr)
        }
    } elseif ($stat.TotalItemSize -is [Microsoft.Exchange.Data.UnlimitedBytes]) {
        $s = $stat.TotalItemSize.ToString()
        if ($s -match '\((\d[\d,]*) bytes\)') {
            $bytesStr = $matches[1] -replace ',', ''
            [long]$totalBytes = [long]::Parse($bytesStr)
        }
    }

    # Falls nicht extrahiert, setze 0
    if (-not $totalBytes) { $totalBytes = 0 }

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

    [PSCustomObject]@{
        DisplayName = $mb.DisplayName
        PrimarySmtpAddress = $mb.PrimarySmtpAddress.ToString()
        RecipientTypeDetails = $mb.RecipientTypeDetails
        ItemCount = $stat.ItemCount
        TotalItemSize_Bytes = $totalBytes
        TotalItemSize = Format-Bytes -Bytes $totalBytes
        IssueWarningQuota = $issueWarningQuota.ToString()
        IssueWarningQuota_Bytes = if ($warnBytes) { $warnBytes } else { $null }
        ProhibitSendQuota = $prohibitSendQuota.ToString()
        ProhibitSendQuota_Bytes = if ($sendBytes) { $sendBytes } else { $null }
        ProhibitSendReceiveQuota = $prohibitSendReceiveQuota.ToString()
        ProhibitSendReceiveQuota_Bytes = if ($sendRecvBytes) { $sendRecvBytes } else { $null }
        LastLogonTime = $stat.LastLogonTime
    }

}

# Ergebnis nach Grösse absteigend sortieren und als CSV im HTTP-Response zurückgeben

$csvLines = $report | Sort-Object -Property TotalItemSize_Bytes -Descending | ConvertTo-Csv -NoTypeInformation
$csvBody = $csvLines -join "`n"

$headers = @{
    "Content-Type" = "text/csv; charset=utf-8"
    "Content-Disposition" = "attachment; filename=GroupMailboxes_Quota.csv"
}

$resp = New-HttpResponse -StatusCode 200 -Body $csvBody -Headers $headers
Push-OutputBinding -Name Response -Value $resp
