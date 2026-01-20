param($Request)

$correlationId = $Request.Params.correlationId
if (-not $correlationId) { $correlationId = $Request.Query.correlationId }
if (-not $correlationId) { $correlationId = "test-" + ([guid]::NewGuid().ToString()) }

$cid = $correlationId
$now = (Get-Date).ToString("o")

$metadata = [pscustomobject]@{
    correlationId     = $cid
    fromEmail         = "tester@example.com"
    fromName          = "Test Sender"
    subject           = "Test HR Intake"
    receivedTime      = $now
    messageId         = [guid]::NewGuid().ToString()
    hasAttachments    = $true

}

$metadataBlob = $metadata | ConvertTo-Json -Depth 5
$attachmentBlob = [System.Text.Encoding]::UTF8.GetBytes("fake attachment content")

Push-OutputBinding -Name metadataBlob -Value $metadata | Out-Null
Push-OutputBinding -Name attachmentBlob -Value $attachmentBlob | Out-Null
