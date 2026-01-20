param($QueueItem, $TriggerMetadata)

Write-Host "Raw queue item: $QueueItem"
try {
	$parsed = $QueueItem | ConvertFrom-Json
} catch {
	Write-Warning "Queue item is not valid JSON; skipping. Error: $_"
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

Write-Host "Attachment event received: $blobUrl"

$correlationId = $null
if ($blobUrl -match "/emails/([^/]+)/attachments/") {
	$correlationId = $matches[1]
}

$doc = [pscustomobject]@{
	id            = [guid]::NewGuid().ToString()
	pk            = $correlationId
	correlationId = $correlationId
	attachmentUrl = $blobUrl
	status        = "Processed"
	processedAt   = (Get-Date).ToString("o")
}

Push-OutputBinding -Name cosmosDoc -Value $doc
