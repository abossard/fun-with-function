# profile.ps1
# Runs on cold start - manages Microsoft Graph change notification subscription
# Creates/renews subscription, activates Partner Topic, creates Event Subscription

$ErrorActionPreference = "Stop"

Write-Host "=== PowerShell Function App Cold Start ==="
Write-Host "Initializing Graph subscription..."

# Configuration from environment
$graphAppClientId = $env:GRAPH_APP_CLIENT_ID
$tenantId = $env:AZURE_TENANT_ID
$uamiClientId = $env:AzureWebJobsStorage__clientId
$prefix = $env:PREFIX ?? "anb888"
$resourceGroup = $env:RESOURCE_GROUP ?? "anbo-ints-usecase-3"
$location = $env:LOCATION ?? "swedencentral"
$azureSubscriptionId = $env:AZURE_SUBSCRIPTION_ID

$partnerTopicName = "$prefix-graph-users-topic"

# Skip if running locally or missing config
if (-not $graphAppClientId -or -not $tenantId -or -not $azureSubscriptionId) {
    Write-Host "Skipping Graph subscription (missing env vars - likely local dev)"
    return
}

# Function to get Graph API token via federated credential
function Get-GraphToken {
    $assertionUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=api://AzureADTokenExchange&client_id=$uamiClientId"
    $assertionResponse = Invoke-RestMethod -Uri $assertionUri -Headers @{ "Metadata" = "true" }
    $assertion = $assertionResponse.access_token
    
    $tokenBody = @{
        client_id = $graphAppClientId
        scope = "https://graph.microsoft.com/.default"
        client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        client_assertion = $assertion
        grant_type = "client_credentials"
    }
    
    $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody
    return $tokenResponse.access_token
}

try {
    $graphToken = Get-GraphToken
    Write-Host "Got Graph API token"
} catch {
    Write-Warning "Failed to get Graph token: $_ - subscription management skipped"
    return
}

$headers = @{
    "Authorization" = "Bearer $graphToken"
    "Content-Type" = "application/json"
}

# Check existing subscriptions
try {
    $existingSubscriptions = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions" -Headers $headers
    $ourSubscription = $existingSubscriptions.value | Where-Object { 
        $_.resource -eq "users" -and $_.notificationUrl -like "*$partnerTopicName*"
    }
    
    if ($ourSubscription) {
        $expirationTime = [DateTime]::Parse($ourSubscription.expirationDateTime)
        $hoursRemaining = ($expirationTime - (Get-Date).ToUniversalTime()).TotalHours
        Write-Host "Existing subscription found, expires in $([Math]::Round($hoursRemaining, 1)) hours"
        
        if ($hoursRemaining -lt 12) {
            Write-Host "Renewing subscription..."
            $newExpiration = (Get-Date).ToUniversalTime().AddDays(2).ToString("yyyy-MM-ddTHH:mm:ssZ")
            $renewBody = @{ expirationDateTime = $newExpiration } | ConvertTo-Json
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions/$($ourSubscription.id)" `
                -Method PATCH -Headers $headers -Body $renewBody | Out-Null
            Write-Host "Subscription renewed"
        }
        return
    }
} catch {
    Write-Warning "Error checking subscriptions: $_"
}

# Create new subscription
Write-Host "Creating Graph subscription for user changes..."

$notificationUrl = "EventGrid:?azuresubscriptionid=$azureSubscriptionId&resourcegroup=$resourceGroup&partnertopic=$partnerTopicName&location=$location"
$expirationDateTime = (Get-Date).ToUniversalTime().AddDays(2).ToString("yyyy-MM-ddTHH:mm:ssZ")

$subscriptionBody = @{
    changeType = "created,updated,deleted"
    notificationUrl = $notificationUrl
    lifecycleNotificationUrl = $notificationUrl
    resource = "users"
    expirationDateTime = $expirationDateTime
    clientState = "$prefix-secret-state"
} | ConvertTo-Json

try {
    $newSubscription = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions" `
        -Method POST -Headers $headers -Body $subscriptionBody
    Write-Host "Graph subscription created: $($newSubscription.id)"
    
    # Wait for Partner Topic provisioning
    Start-Sleep -Seconds 10
    
    # Activate Partner Topic and create Event Subscription
    $armToken = (Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/&client_id=$uamiClientId" -Headers @{ "Metadata" = "true" }).access_token
    $armHeaders = @{
        "Authorization" = "Bearer $armToken"
        "Content-Type" = "application/json"
    }
    
    $partnerTopicUrl = "https://management.azure.com/subscriptions/$azureSubscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.EventGrid/partnerTopics/$partnerTopicName"
    
    # Activate Partner Topic
    try {
        $activateBody = @{ properties = @{ activationState = "Activated" } } | ConvertTo-Json -Depth 3
        Invoke-RestMethod -Uri "$partnerTopicUrl`?api-version=2024-06-01-preview" -Method PATCH -Headers $armHeaders -Body $activateBody | Out-Null
        Write-Host "Partner Topic activated"
    } catch { Write-Warning "Partner Topic activation: $_" }
    
    # Create Event Subscription
    $eventSubName = "$prefix-user-changes-sub"
    $eventSubUrl = "$partnerTopicUrl/eventSubscriptions/$eventSubName`?api-version=2024-06-01-preview"
    $storageAccountId = "/subscriptions/$azureSubscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Storage/storageAccounts/${prefix}storage"
    
    $eventSubBody = @{
        properties = @{
            destination = @{
                endpointType = "StorageQueue"
                properties = @{
                    resourceId = $storageAccountId
                    queueName = "hr-user-changes-q"
                }
            }
            eventDeliverySchema = "CloudEventSchemaV1_0"
        }
    } | ConvertTo-Json -Depth 5
    
    try {
        Invoke-RestMethod -Uri $eventSubUrl -Method PUT -Headers $armHeaders -Body $eventSubBody | Out-Null
        Write-Host "Event Subscription created"
    } catch { Write-Warning "Event Subscription: $_" }
    
} catch {
    Write-Warning "Failed to create Graph subscription: $_"
}

Write-Host "=== Cold Start Complete ==="
