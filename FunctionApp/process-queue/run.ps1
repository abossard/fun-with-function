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
$cosmosConn = $env:CosmosDBConnection
$database = "hrdb"
$containerName = "emails"

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

# Upsert into Cosmos DB
Write-Host "Writing document for correlationId $($doc.correlationId)"
$client = New-AzCosmosDBV2Client -ConnectionString $cosmosConn
New-AzCosmosDBV2Document -Client $client -Database $database -Container $containerName -DocumentBody ($doc | ConvertTo-Json -Depth 5) | Out-Null

# Return correlation id for logging
Push-OutputBinding -Name res -Value $doc.correlationId
