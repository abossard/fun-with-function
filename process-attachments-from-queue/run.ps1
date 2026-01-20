param($QueueItem, $TriggerMetadata)

$evt = $QueueItem | ConvertFrom-Json
$data = $evt.data
$blobUrl = $data.url
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
