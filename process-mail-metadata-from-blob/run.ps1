param($queueItem, $TriggerMetadata)

Write-Host "Raw queue item: $queueItem"

# Parse CloudEvent from queue message
$parsed = $null
if ($queueItem -is [string]) {
    try {
        $parsed = $queueItem | ConvertFrom-Json
    } catch {
        Write-Warning "Queue item string is not valid JSON; skipping. Error: $_"
        return
    }
} elseif ($queueItem -is [System.Collections.IDictionary] -or $queueItem -is [psobject]) {
    $parsed = $queueItem
} else {
    Write-Warning "Queue item is of unsupported type '$($queueItem.GetType().FullName)'; skipping."
    return
}

$evt = if ($parsed -is [System.Array]) { $parsed[0] } else { $parsed }
if (-not $evt.data) {
    Write-Warning "Event missing data payload; skipping."
    return
}

$blobUrl = $evt.data.url
if (-not $blobUrl) {
    Write-Warning "Event missing blob url; skipping."
    return
}

Write-Host "Metadata blob event received: $blobUrl"

# Extract correlationId from blob URL
$correlationId = $null
if ($blobUrl -match "/emails/metadata/([^/]+)/metadata\.json") {
    $correlationId = $matches[1]
}

# Parse URL to get storage account, container, and blob path
# Example: https://anb888storage.blob.core.windows.net/emails/metadata/123/metadata.json
if ($blobUrl -match "https://([^.]+)\.blob\.core\.windows\.net/([^/]+)/(.+)") {
    $storageAccountName = $matches[1]
    $containerName = $matches[2]
    $blobPath = $matches[3]
} else {
    Write-Warning "Unable to parse blob URL: $blobUrl"
    return
}

# Read blob content using managed identity
try {
    $clientId = $env:AzureWebJobsStorage__clientId
    $context = New-AzStorageContext -StorageAccountName $storageAccountName -ManagedIdentityClientId $clientId
    $blobContent = Get-AzStorageBlobContent -Container $containerName -Blob $blobPath -Context $context -Force -ErrorAction Stop
    $metadataJson = Get-Content -Path $blobPath -Raw
    Remove-Item -Path $blobPath -Force -ErrorAction SilentlyContinue
} catch {
    Write-Warning "Failed to read blob: $_"
    return
}

try {
    $metadata = $metadataJson | ConvertFrom-Json
} catch {
    Write-Warning "Metadata blob is not valid JSON; skipping. Error: $_"
    return
}

# Use correlationId from metadata if available
if (-not $correlationId -and $metadata.correlationId) {
    $correlationId = $metadata.correlationId
}

$doc = [pscustomobject]@{
    id             = $metadata.messageId
    pk             = $metadata.fromEmail
    correlationId  = $correlationId
    fromEmail      = $metadata.fromEmail
    fromName       = $metadata.fromName
    subject        = $metadata.subject
    receivedTime   = $metadata.receivedTime
    hasAttachments = $metadata.hasAttachments
    messageId      = $metadata.messageId
    createdAt      = (Get-Date).ToString("o")
}

Write-Host "Writing document for correlationId $($doc.correlationId)"
$cosmosDisabled = ($env:DISABLE_COSMOS_OUTPUT -eq "true")
if (-not $cosmosDisabled) {
    Push-OutputBinding -Name cosmosDoc -Value $doc
} else {
    Write-Host "Cosmos output skipped (DISABLE_COSMOS_OUTPUT=true)."
}
