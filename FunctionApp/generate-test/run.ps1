param($Request, $Response, $metadataBlob, $attachmentBlob, $queueMsg, $correlationId)

if (-not $correlationId) {
    $Response = @{
        statusCode = 400
        body       = "correlationId route parameter is required"
    }
    return
}

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

$Response = @{
    statusCode = 200
    body       = @{
        correlationId = $cid
        metadataPath  = $metadataPath
        attachmentPath = $attachmentPath
    } | ConvertTo-Json
}
