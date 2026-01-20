param($metadata, $TriggerMetadata)

Write-Host "Blob trigger path: $($TriggerMetadata.BlobTrigger)"

if (-not $metadata) {
    Write-Warning "Metadata blob is empty; skipping."
    return
}

try {
    $parsed = $metadata | ConvertFrom-Json
} catch {
    Write-Warning "Metadata blob is not valid JSON; skipping. Error: $_"
    return
}

$correlationId = $null
if ($TriggerMetadata.BlobTrigger -match "emails/metadata/([^/]+)/metadata.json") {
    $correlationId = $matches[1]
}

$doc = [pscustomobject]@{
    id                 = $parsed.messageId
    pk                 = $parsed.fromEmail
    correlationId      = $parsed.correlationId
    fromEmail          = $parsed.fromEmail
    fromName           = $parsed.fromName
    subject            = $parsed.subject
    receivedTime       = $parsed.receivedTime
    hasAttachments     = $parsed.hasAttachments
    messageId          = $parsed.messageId
    createdAt          = (Get-Date).ToString("o")
}

Write-Host "Writing document for correlationId $($doc.correlationId)"
$cosmosDisabled = ($env:DISABLE_COSMOS_OUTPUT -eq "true")
if (-not $cosmosDisabled) {
    Push-OutputBinding -Name cosmosDoc -Value $doc
} else {
    Write-Host "Cosmos output skipped (DISABLE_COSMOS_OUTPUT=true)."
}
