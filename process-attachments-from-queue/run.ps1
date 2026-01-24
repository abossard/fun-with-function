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

Write-Host "Graph data file event received: $blobUrl"
# https://anb99storage.blob.core.windows.net/graphSnapshots/attachments/333333333333/fake.txt
$snapshotId = $null
if ($blobUrl -match "/graphSnapshots/attachments/([^/]+)/") {
	$snapshotId = $matches[1]
} elseif ($blobUrl -match "/attachments/([^/]+)/") {
	# Fallback if path omits leading 'graphSnapshots/'
	$snapshotId = $matches[1]
} elseif ($blobUrl -match "/graphSnapshots/([^/]+)/attachments/") {
	# Legacy pattern graphSnapshots/{sid}/attachments/
	$snapshotId = $matches[1]
}

if (-not $snapshotId) {
	Write-Warning "Unable to extract snapshotId from blob url: $blobUrl"
}

$doc = [pscustomobject]@{
	id          = [guid]::NewGuid().ToString()
	pk          = $snapshotId
	snapshotId  = $snapshotId
	dataFileUrl = $blobUrl
	status      = "Processed"
	processedAt = (Get-Date).ToString("o")
}

Start-Sleep -Seconds 120
# have a 10% chance to simulate failure
$rand = Get-Random -Minimum 1 -Maximum 6
if ($rand -eq 1) {
	Write-Error "Simulated random processing failure."
	return
}

Push-OutputBinding -Name cosmosDoc -Value $doc
