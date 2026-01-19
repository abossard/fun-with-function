param($Request)

$correlationId = $Request.Params.correlationId
if (-not $correlationId) { $correlationId = $Request.Query.correlationId }
if (-not $correlationId) { $correlationId = "test-" + ([guid]::NewGuid().ToString()) }

$cid = $correlationId
$now = (Get-Date).ToString("o")
$attachmentPath = "emails/$cid/attachments/fake.txt"
$metadataPath = "emails/$cid/metadata.json"

$metadata = [pscustomobject]@{
    correlationId     = $cid
    fromEmail         = "tester@example.com"
    fromName          = "Test Sender"
    subject           = "Test HR Intake"
    receivedTime      = $now
    messageId         = [guid]::NewGuid().ToString()
    hasAttachments    = $true
    attachmentBlobPaths = @($attachmentPath)
}

$metadataBlob = $metadata | ConvertTo-Json -Depth 5
$attachmentBlob = [System.Text.Encoding]::UTF8.GetBytes("fake attachment content")

$queueMsg = @{
    specversion = "1.0"
    id          = [guid]::NewGuid().ToString()
    type        = "com.example.attachment.created"
    source      = "/tests/generator"
    subject     = $attachmentPath
    time        = $now
    data        = @{
        correlationId  = $cid
        attachmentPath = $attachmentPath
        metadataPath   = $metadataPath
    }
} | ConvertTo-Json -Depth 5

Push-OutputBinding -Name metadataBlob -Value $metadata | Out-Null
Push-OutputBinding -Name attachmentBlob -Value $attachmentBlob | Out-Null
Push-OutputBinding -Name queueMsg -Value $queueMsg | Out-Null
Push-OutputBinding -Name Response -Value (@{
    statusCode = 200
    body       = @{
        correlationId = $cid
        metadataPath  = $metadataPath
        attachmentPath = $attachmentPath
    } | ConvertTo-Json
})
