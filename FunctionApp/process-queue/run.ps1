using namespace System.Text.Json

param($QueueItem, $TriggerMetadata)

# Expect queue payload with storage event grid data
$event = $QueueItem | ConvertFrom-Json
$data = $event.data
$blobUrl = $data.url

# correlationId assumed in path: emails/{correlationId}/metadata.json
$segments = $blobUrl -split "/"
$blobName = $segments[-1]
$correlationId = $segments[-2]
$container = "emails"

$storageConnection = $env:AzureWebJobsStorage
# Download metadata.json
$ctx = New-AzStorageContext -ConnectionString $storageConnection
$content = (Get-AzStorageBlobContent -Blob "$correlationId/$blobName" -Container $container -Context $ctx -Force -Destination (New-TemporaryFile)).Content | Get-Content -Raw
$metadata = $content | ConvertFrom-Json

$doc = [pscustomobject]@{
    id            = $metadata.messageId
    pk            = $metadata.fromEmail
    correlationId = $metadata.correlationId
    fromEmail     = $metadata.fromEmail
    fromName      = $metadata.fromName
    subject       = $metadata.subject
    receivedTime  = $metadata.receivedTime
    hasAttachments= $metadata.hasAttachments
    attachmentBlobPaths = $metadata.attachmentBlobPaths
    messageId     = $metadata.messageId
    createdAt     = (Get-Date).ToString("o")
}

# Return correlation id for logging and emit doc to Cosmos output binding
Write-Host "Writing document for correlationId $($doc.correlationId)"
Push-OutputBinding -Name cosmosDoc -Value $doc
