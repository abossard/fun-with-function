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

$blobSubject = "/blobServices/default/containers/emails/blobs/$attachmentPath"
$blobUrl = "http://127.0.0.1:10000/devstoreaccount1/$attachmentPath"

$queueMsg = @{
    specversion     = "1.0"
    id              = [guid]::NewGuid().ToString()
    type            = "Microsoft.Storage.BlobCreated"
    source          = "/tests/generator"
    subject         = $blobSubject
    time            = $now
    datacontenttype = "application/json"
    data            = @{
        api              = "PutBlob"
        url              = $blobUrl
        contentType      = "text/plain"
        contentLength    = $attachmentBlob.Length
        blobType         = "BlockBlob"
        clientRequestId  = [guid]::NewGuid().ToString()
        requestId        = [guid]::NewGuid().ToString()
        eTag             = "0x8D0000000000000"
        sequencer        = "00000000000000000000000000000000"
        storageDiagnostics = @{
            batchId = [guid]::NewGuid().ToString()
        }
    }
} | ConvertTo-Json -Depth 6

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
