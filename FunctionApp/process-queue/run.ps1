using namespace System.Text.Json

param($metadata, $TriggerMetadata)

# Blob trigger already gives us metadata content; path format emails/{correlationId}/metadata.json
$correlationId = $TriggerMetadata.Name.Split("/")[1]
$metadata = $metadata | ConvertFrom-Json

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
$cosmosDisabled = ($env:DISABLE_COSMOS_OUTPUT -eq "true")
if (-not $cosmosDisabled) {
    Push-OutputBinding -Name cosmosDoc -Value $doc
} else {
    Write-Host "Cosmos output skipped (DISABLE_COSMOS_OUTPUT=true)."
}
