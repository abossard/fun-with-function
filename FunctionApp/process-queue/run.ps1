using namespace System.Text.Json

param($metadata, $existingDoc, $TriggerMetadata)

# Blob trigger already gives us metadata content; path format emails/{correlationId}/metadata.json
$correlationId = $TriggerMetadata.Name.Split("/")[1]
$metadata = $metadata | ConvertFrom-Json
$existing = $existingDoc

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
    createdAt     = if ($existing) { $existing.createdAt } else { (Get-Date).ToString("o") }
}

# Return correlation id for logging and emit doc to Cosmos output binding
Write-Host "Writing document for correlationId $($doc.correlationId)"
Push-OutputBinding -Name cosmosDoc -Value $doc
