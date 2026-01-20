param($QueueItem, $TriggerMetadata)

Write-Host "Raw queue item: $QueueItem"

# Handle Event Grid messages delivered to storage queue: runtime may give a hash table already
$parsed = $null
if ($QueueItem -is [string]) {
	try {
		$parsed = $QueueItem | ConvertFrom-Json
	} catch {
		Write-Warning "Queue item string is not valid JSON; skipping. Error: $_"
		return
	}
} elseif ($QueueItem -is [System.Collections.IDictionary] -or $QueueItem -is [psobject]) {
	$parsed = $QueueItem
} elseif ($QueueItem -is [System.Array]) {
	$parsed = $QueueItem
} else {
	Write-Warning "Queue item is of unsupported type '$($QueueItem.GetType().FullName)'; skipping."
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
if ($blobUrl -match "/emails/attachments/([^/]+)/") {
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
