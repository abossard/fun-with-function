# process-user-changes/run.ps1
# Triggered by Microsoft Graph Change Notifications for Entra ID user changes
# Events arrive via Event Grid Partner Topic → Storage Queue
# Also handles lifecycle events (ReauthorizationRequired) to trigger subscription renewal

using namespace System.Net

param($QueueItem, $TriggerMetadata)

Write-Host "Processing event from Graph API Partner Topic"

# Parse the event - Graph sends CloudEvent format via Event Grid
$event = $null
if ($QueueItem -is [string]) {
    $event = $QueueItem | ConvertFrom-Json
} else {
    $event = $QueueItem
}

$eventType = $event.type
Write-Host "Event Type: $eventType"

# Handle lifecycle events (reauthorization required)
if ($eventType -eq "Microsoft.Graph.SubscriptionReauthorizationRequired") {
    Write-Host "Lifecycle Event: Subscription needs reauthorization"
    
    # Renew the subscription inline
    try {
        $graphAppClientId = $env:GRAPH_APP_CLIENT_ID
        $tenantIdEnv = $env:AZURE_TENANT_ID
        $uamiClientId = $env:AzureWebJobsStorage__clientId
        $identityEndpoint = $env:IDENTITY_ENDPOINT
        $identityHeader = $env:IDENTITY_HEADER
        
        # Get Graph token using App Service MSI endpoint
        $assertionUri = "$identityEndpoint`?api-version=2019-08-01&resource=api://AzureADTokenExchange&client_id=$uamiClientId"
        $assertionResponse = Invoke-RestMethod -Uri $assertionUri -Headers @{ "X-IDENTITY-HEADER" = $identityHeader }
        $tokenBody = @{
            client_id = $graphAppClientId
            scope = "https://graph.microsoft.com/.default"
            client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
            client_assertion = $assertionResponse.access_token
            grant_type = "client_credentials"
        }
        $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantIdEnv/oauth2/v2.0/token" -Method POST -Body $tokenBody
        
        # Renew subscription
        $subscriptionId = $event.data.subscriptionId
        $newExpiration = (Get-Date).ToUniversalTime().AddDays(2).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $renewBody = @{ expirationDateTime = $newExpiration } | ConvertTo-Json
        
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions/$subscriptionId" `
            -Method PATCH -Headers @{ "Authorization" = "Bearer $($tokenResponse.access_token)"; "Content-Type" = "application/json" } `
            -Body $renewBody | Out-Null
        
        Write-Host "Subscription renewed until $newExpiration"
    } catch {
        Write-Error "Failed to renew subscription: $_"
    }
    return
}

# Handle subscription deleted events
if ($eventType -eq "Microsoft.Graph.SubscriptionDeleted") {
    Write-Warning "Graph subscription was deleted! Will be recreated on next cold start."
    return
}

Write-Host "Event Subject: $($event.subject)"

# Extract event data
$eventData = $event.data

# Graph change notification structure
$changeType = $eventData.changeType  # created, updated, deleted
$resourceId = $eventData.resourceData.id
$tenantId = $eventData.tenantId
$clientState = $eventData.clientState

Write-Host "Change Type: $changeType"
Write-Host "Resource ID (User ID): $resourceId"
Write-Host "Tenant ID: $tenantId"

# Validate client state (optional security check)
$prefix = $env:PREFIX ?? "anb888"
$expectedClientState = "$prefix-secret-state"
if ($clientState -and $clientState -ne $expectedClientState) {
    Write-Warning "Client state mismatch - possible spoofed event"
}

# Process the user change
$timestamp = Get-Date -Format "o"
$documentId = [Guid]::NewGuid().ToString()

# Create a document to store in Cosmos DB
$outputDocument = @{
    id = $documentId
    pk = "user-change"
    eventType = $eventType
    changeType = $changeType
    userId = $resourceId
    tenantId = $tenantId
    timestamp = $timestamp
    rawEvent = $event
}

# If it's an update or create, fetch additional user details (optional)
if ($changeType -in @("created", "updated") -and $resourceId) {
    try {
        # Get Graph token via federated credential
        $graphAppClientId = $env:GRAPH_APP_CLIENT_ID
        $tenantIdEnv = $env:AZURE_TENANT_ID
        $uamiClientId = $env:AzureWebJobsStorage__clientId
        $identityEndpoint = $env:IDENTITY_ENDPOINT
        $identityHeader = $env:IDENTITY_HEADER
        
        if ($graphAppClientId -and $tenantIdEnv -and $identityEndpoint) {
            Write-Host "Fetching user details from Graph API..."
            
            # Get assertion token using App Service MSI endpoint
            $assertionUri = "$identityEndpoint`?api-version=2019-08-01&resource=api://AzureADTokenExchange&client_id=$uamiClientId"
            $assertionResponse = Invoke-RestMethod -Uri $assertionUri -Headers @{ "X-IDENTITY-HEADER" = $identityHeader }
            $assertion = $assertionResponse.access_token
            
            # Exchange for Graph token
            $tokenBody = @{
                client_id = $graphAppClientId
                scope = "https://graph.microsoft.com/.default"
                client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
                client_assertion = $assertion
                grant_type = "client_credentials"
            }
            $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantIdEnv/oauth2/v2.0/token" -Method POST -Body $tokenBody
            $graphToken = $tokenResponse.access_token
            
            # Fetch user details
            $userResponse = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$resourceId" `
                -Headers @{ "Authorization" = "Bearer $graphToken" } `
                -ErrorAction SilentlyContinue
            
            if ($userResponse) {
                $outputDocument.userDetails = @{
                    displayName = $userResponse.displayName
                    userPrincipalName = $userResponse.userPrincipalName
                    mail = $userResponse.mail
                    jobTitle = $userResponse.jobTitle
                    department = $userResponse.department
                }
                Write-Host "User: $($userResponse.displayName) ($($userResponse.userPrincipalName))"
            }
        }
    } catch {
        Write-Warning "Could not fetch user details: $_"
    }
}

# Output to Cosmos DB
Push-OutputBinding -Name outputDocument -Value $outputDocument

Write-Host "User change event processed and stored in Cosmos DB"
Write-Host "Document ID: $documentId"
