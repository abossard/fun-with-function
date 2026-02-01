param($Request)

function New-HttpResponse {
    param([int]$StatusCode, $Body)
    return @{
        StatusCode = $StatusCode
        Body = ($Body | ConvertTo-Json -Depth 10)
        Headers = @{ "Content-Type" = "application/json" }
    }
}

$sharedScript = Join-Path $PSScriptRoot ".." "shared/graph-subscription.ps1"
$errors = @()

if (Test-Path $sharedScript) {
    . $sharedScript
    try {
        Ensure-GraphChangeSubscription
    } catch {
        $errors += "Ensure-GraphChangeSubscription failed: $_"
    }
} else {
    $errors += "Shared helper not found: $sharedScript"
}

$requiredSettings = @(
    "GRAPH_APP_CLIENT_ID",
    "AZURE_TENANT_ID",
    "AZURE_SUBSCRIPTION_ID",
    "RESOURCE_GROUP",
    "LOCATION",
    "PREFIX",
    "GRAPH_PARTNER_TOPIC_NAME",
    "GRAPH_PARTNER_EVENT_SUB_NAME",
    "GRAPH_USER_CHANGES_QUEUE_NAME",
    "GRAPH_RESOURCE",
    "GRAPH_CHANGE_TYPE",
    "GRAPH_CLIENT_STATE",
    "AzureWebJobsStorage__clientId",
    "AzureWebJobsStorage__accountName",
    "MANAGED_IDENTITY_RESOURCE_ID"
)

$missingSettings = @()
foreach ($name in $requiredSettings) {
    if (-not (Get-Item -Path "Env:\$name" -ErrorAction SilentlyContinue)) { $missingSettings += $name }
}

function Get-GraphToken {
    $identityEndpoint = $env:IDENTITY_ENDPOINT
    $identityHeader = $env:IDENTITY_HEADER
    $uamiClientId = $env:AzureWebJobsStorage__clientId

    if (-not $identityEndpoint -or -not $identityHeader -or -not $uamiClientId) {
        throw "Missing managed identity environment variables."
    }

    $assertionUri = "$identityEndpoint`?api-version=2019-08-01&resource=api://AzureADTokenExchange&client_id=$uamiClientId"
    $assertionResponse = Invoke-RestMethod -Uri $assertionUri -Headers @{ "X-IDENTITY-HEADER" = $identityHeader } -ErrorAction Stop
    $assertion = $assertionResponse.access_token

    $tokenBody = @{
        client_id = $env:GRAPH_APP_CLIENT_ID
        scope = "https://graph.microsoft.com/.default"
        client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        client_assertion = $assertion
        grant_type = "client_credentials"
    }

    $tokenUrl = "https://login.microsoftonline.com/$($env:AZURE_TENANT_ID)/oauth2/v2.0/token"
    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method POST -Body $tokenBody -ErrorAction Stop
    return $tokenResponse.access_token
}

function Get-ArmToken {
    $identityEndpoint = $env:IDENTITY_ENDPOINT
    $identityHeader = $env:IDENTITY_HEADER
    $uamiClientId = $env:AzureWebJobsStorage__clientId

    if (-not $identityEndpoint -or -not $identityHeader -or -not $uamiClientId) {
        throw "Missing managed identity environment variables."
    }

    $armUri = "$identityEndpoint`?api-version=2019-08-01&resource=https://management.azure.com/&client_id=$uamiClientId"
    $response = Invoke-RestMethod -Uri $armUri -Headers @{ "X-IDENTITY-HEADER" = $identityHeader } -ErrorAction Stop
    return $response.access_token
}

$graphSubscription = $null
$partnerTopic = $null
$eventSubscription = $null

try {
    $graphToken = Get-GraphToken
    $graphHeaders = @{ Authorization = "Bearer $graphToken"; "Content-Type" = "application/json" }

    $subs = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions" -Headers $graphHeaders
    $graphSubscription = $subs.value | Where-Object {
        $_.resource -eq $env:GRAPH_RESOURCE -and $_.notificationUrl -match "partnertopic=$($env:GRAPH_PARTNER_TOPIC_NAME)"
    } | Select-Object -First 1
} catch {
    $errors += "Graph subscription lookup failed: $_"
}

try {
    $armToken = Get-ArmToken
    $armHeaders = @{ Authorization = "Bearer $armToken"; "Content-Type" = "application/json" }

    $partnerTopicUrl = "https://management.azure.com/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:RESOURCE_GROUP)/providers/Microsoft.EventGrid/partnerTopics/$($env:GRAPH_PARTNER_TOPIC_NAME)?api-version=2024-06-01-preview"
    $partnerTopic = Invoke-RestMethod -Uri $partnerTopicUrl -Headers $armHeaders -Method GET -ErrorAction Stop

    $eventSubUrl = "https://management.azure.com/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:RESOURCE_GROUP)/providers/Microsoft.EventGrid/partnerTopics/$($env:GRAPH_PARTNER_TOPIC_NAME)/eventSubscriptions/$($env:GRAPH_PARTNER_EVENT_SUB_NAME)?api-version=2025-07-15-preview"
    $eventSubscription = Invoke-RestMethod -Uri $eventSubUrl -Headers $armHeaders -Method GET -ErrorAction Stop
} catch {
    $errors += "ARM Event Grid lookup failed: $_"
}

$response = @{
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    ok = ($errors.Count -eq 0)
    missingSettings = $missingSettings
    environment = @{
        prefix = $env:PREFIX
        resourceGroup = $env:RESOURCE_GROUP
        location = $env:LOCATION
        subscriptionId = $env:AZURE_SUBSCRIPTION_ID
        tenantId = $env:AZURE_TENANT_ID
        storageAccountName = $env:AzureWebJobsStorage__accountName
        partnerTopicName = $env:GRAPH_PARTNER_TOPIC_NAME
        partnerEventSubscriptionName = $env:GRAPH_PARTNER_EVENT_SUB_NAME
        userChangesQueueName = $env:GRAPH_USER_CHANGES_QUEUE_NAME
        graphResource = $env:GRAPH_RESOURCE
        graphChangeType = $env:GRAPH_CHANGE_TYPE
    }
    graphSubscription = if ($graphSubscription) {
        @{
            id = $graphSubscription.id
            resource = $graphSubscription.resource
            changeType = $graphSubscription.changeType
            expirationDateTime = $graphSubscription.expirationDateTime
            notificationUrl = $graphSubscription.notificationUrl
            lifecycleNotificationUrl = $graphSubscription.lifecycleNotificationUrl
            clientStateSet = -not [string]::IsNullOrEmpty($graphSubscription.clientState)
        }
    } else { $null }
    partnerTopic = if ($partnerTopic) {
        @{
            id = $partnerTopic.id
            activationState = $partnerTopic.properties.activationState
            provisioningState = $partnerTopic.properties.provisioningState
        }
    } else { $null }
    eventSubscription = if ($eventSubscription) {
        @{
            id = $eventSubscription.id
            provisioningState = $eventSubscription.properties.provisioningState
            destination = $eventSubscription.properties.destination
            statusMessage = $eventSubscription.properties.statusMessage
        }
    } else { $null }
    errors = $errors
}

$statusCode = if ($errors.Count -eq 0 -and $missingSettings.Count -eq 0) { 200 } else { 500 }
Push-OutputBinding -Name Response -Value (New-HttpResponse -StatusCode $statusCode -Body $response)
