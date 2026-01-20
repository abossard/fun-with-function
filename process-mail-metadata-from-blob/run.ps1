param($eventGridEvent, $TriggerMetadata)

Write-Host "Raw Event Grid event: $eventGridEvent"
try {
    $evt = $eventGridEvent | ConvertFrom-Json
} catch {
    Write-Warning "Event Grid payload is not JSON; skipping. Error: $_"
    return
}

# Handle array vs single event payloads
$payload = if ($evt -is [System.Array]) { $evt[0] } else { $evt }
if (-not $payload.data) {
    Write-Warning "Event Grid payload missing data; skipping."
    return
}

# Expect data.url to point to the metadata blob
$metadataUrl = $payload.data.url
if (-not $metadataUrl) {
    Write-Warning "Event Grid payload missing data.url; skipping."
    return
}

# Derive correlationId from the blob path emails/{cid}/metadata.json
$correlationId = $null
if ($metadataUrl -match "/emails/([^/]+)/metadata.json") {
    $correlationId = $matches[1]
}

# Fetch the blob content using managed identity auth via Az.Storage module
try {
    $ctx = (Get-AzStorageAccount -Name $env:AzureWebJobsStorage__accountName -ResourceGroupName $env:WEBSITE_RESOURCE_GROUP).Context
    $blob = Get-AzStorageBlobContent -Container "emails" -Blob "${correlationId}/metadata.json" -Context $ctx -Force -ErrorAction Stop
    $metadataJson = Get-Content $blob.Name -Raw
} catch {
    Write-Warning "Failed to read metadata blob for $correlationId: $_"
    return
}

try {
    $metadata = $metadataJson | ConvertFrom-Json
} catch {
    Write-Warning "Metadata blob is not valid JSON; skipping. Error: $_"
    return
}

$doc = [pscustomobject]@{
    id                 = $metadata.messageId
    pk                 = $metadata.fromEmail
    correlationId      = $metadata.correlationId
    fromEmail          = $metadata.fromEmail
    fromName           = $metadata.fromName
    subject            = $metadata.subject
    receivedTime       = $metadata.receivedTime
    hasAttachments     = $metadata.hasAttachments
    attachmentBlobPaths= $metadata.attachmentBlobPaths
    messageId          = $metadata.messageId
    createdAt          = (Get-Date).ToString("o")
}

Write-Host "Writing document for correlationId $($doc.correlationId)"
$cosmosDisabled = ($env:DISABLE_COSMOS_OUTPUT -eq "true")
if (-not $cosmosDisabled) {
    Push-OutputBinding -Name cosmosDoc -Value $doc
} else {
    Write-Host "Cosmos output skipped (DISABLE_COSMOS_OUTPUT=true)."
}
