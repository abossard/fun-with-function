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

# Function to get Graph API token via federated credential (with retry)
# Uses App Service managed identity endpoint (not IMDS 169.254.169.254)
function Get-GraphToken {
    $maxRetries = 3
    $retryDelay = 2
    
    # App Service/Functions uses IDENTITY_ENDPOINT, not IMDS
    $identityEndpoint = $env:IDENTITY_ENDPOINT
    $identityHeader = $env:IDENTITY_HEADER
    
    if (-not $identityEndpoint -or -not $identityHeader) {
        throw "Managed identity endpoint not available (IDENTITY_ENDPOINT or IDENTITY_HEADER missing)"
    }
    
    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            # Get assertion token for federation using App Service MSI endpoint
            $assertionUri = "$identityEndpoint`?api-version=2019-08-01&resource=api://AzureADTokenExchange&client_id=$uamiClientId"
            $assertionResponse = Invoke-RestMethod -Uri $assertionUri -Headers @{ "X-IDENTITY-HEADER" = $identityHeader } -TimeoutSec 10
            $assertion = $assertionResponse.access_token
            
            $tokenBody = @{
                client_id = $graphAppClientId
                scope = "https://graph.microsoft.com/.default"
                client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
                client_assertion = $assertion
                grant_type = "client_credentials"
            }
            
            $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody -TimeoutSec 10
            return $tokenResponse.access_token
        } catch {
            if ($i -lt $maxRetries) {
                Write-Host "Token attempt $i failed, retrying in ${retryDelay}s..."
                Start-Sleep -Seconds $retryDelay
                $retryDelay *= 2
            } else {
                throw $_
            }
        }
    }
}

# Function to get ARM token for Azure management operations
function Get-ArmToken {
    $identityEndpoint = $env:IDENTITY_ENDPOINT
    $identityHeader = $env:IDENTITY_HEADER
    
    $armUri = "$identityEndpoint`?api-version=2019-08-01&resource=https://management.azure.com/&client_id=$uamiClientId"
    $response = Invoke-RestMethod -Uri $armUri -Headers @{ "X-IDENTITY-HEADER" = $identityHeader } -TimeoutSec 10
    return $response.access_token
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
    Write-Host "Found $($existingSubscriptions.value.Count) existing Graph subscription(s)"
    
    # Look for any subscription on users resource (may have different partner topic name in URL)
    $ourSubscription = $existingSubscriptions.value | Where-Object { 
        $_.resource -eq "users"
    } | Select-Object -First 1
    
    if ($ourSubscription) {
        $expirationTime = [DateTime]::Parse($ourSubscription.expirationDateTime)
        $hoursRemaining = ($expirationTime - (Get-Date).ToUniversalTime()).TotalHours
        Write-Host "Existing users subscription found (ID: $($ourSubscription.id)), expires in $([Math]::Round($hoursRemaining, 1)) hours"
        
        if ($hoursRemaining -lt 12) {
            Write-Host "Renewing subscription..."
            $newExpiration = (Get-Date).ToUniversalTime().AddDays(2).ToString("yyyy-MM-ddTHH:mm:ssZ")
            $renewBody = @{ expirationDateTime = $newExpiration } | ConvertTo-Json
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions/$($ourSubscription.id)" `
                -Method PATCH -Headers $headers -Body $renewBody | Out-Null
            Write-Host "Subscription renewed"
        }
    }
} catch {
    Write-Warning "Error checking subscriptions: $_"
}

# Always ensure Event Subscription exists on Partner Topic (whether Graph sub exists or not)
Write-Host "Ensuring Event Subscription on Partner Topic..."
try {
    $armToken = Get-ArmToken
    $armHeaders = @{
        "Authorization" = "Bearer $armToken"
        "Content-Type" = "application/json"
    }
    $partnerTopicUrl = "https://management.azure.com/subscriptions/$azureSubscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.EventGrid/partnerTopics/$partnerTopicName"
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
    
    Invoke-RestMethod -Uri $eventSubUrl -Method PUT -Headers $armHeaders -Body $eventSubBody | Out-Null
    Write-Host "Event Subscription ensured on Partner Topic"
} catch {
    Write-Warning "Event Subscription creation failed: $_"
}

# If no Graph subscription exists, try to create one
if (-not $ourSubscription) {
    Write-Host "No Graph subscription found, creating..."
    
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
        
        # Wait for Partner Topic provisioning then activate
        Start-Sleep -Seconds 10
        try {
            $activateBody = @{ properties = @{ activationState = "Activated" } } | ConvertTo-Json -Depth 3
            Invoke-RestMethod -Uri "$partnerTopicUrl`?api-version=2024-06-01-preview" -Method PATCH -Headers $armHeaders -Body $activateBody | Out-Null
            Write-Host "Partner Topic activated"
        } catch { Write-Warning "Partner Topic activation: $_" }
    } catch {
        # Partner Topic may already exist from previous subscription - that's OK if Event Sub is created
        Write-Warning "Graph subscription creation: $_"
    }
}

Write-Host "=== Cold Start Complete ==="
