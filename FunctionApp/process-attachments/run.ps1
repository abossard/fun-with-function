param($QueueItem, $TriggerMetadata)

$evt = $QueueItem | ConvertFrom-Json
$data = $evt.data
$blobUrl = $data.url
Write-Host "Attachment event received: $blobUrl"
