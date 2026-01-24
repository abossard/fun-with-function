# shared/graph-subscription.ps1
# Shared helper to ensure Microsoft Graph change notification subscription and Event Grid wiring

function Ensure-GraphChangeSubscription {
    [CmdletBinding()]
    param(
        [string]$Prefix = ($env:PREFIX ?? "anb888"),
        [string]$ResourceGroup = ($env:RESOURCE_GROUP ?? "anbo-ints-usecase-3"),
        [string]$Location = ($env:LOCATION ?? "swedencentral"),
        [string]$GraphAppClientId = $env:GRAPH_APP_CLIENT_ID,
        [string]$TenantId = $env:AZURE_TENANT_ID,
        [string]$AzureSubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
        [string]$UamiClientId = $env:AzureWebJobsStorage__clientId,
        [string]$ManagedIdentityResourceId = $env:MANAGED_IDENTITY_RESOURCE_ID,
        [string]$StorageAccountName = $env:AzureWebJobsStorage__accountName,
        [string]$PartnerTopicName = $env:GRAPH_PARTNER_TOPIC_NAME,
        [string]$PartnerEventSubscriptionName = $env:GRAPH_PARTNER_EVENT_SUB_NAME,
        [string]$UserChangesQueueName = $env:GRAPH_USER_CHANGES_QUEUE_NAME
    )

    $ErrorActionPreference = "Stop"

    if (-not $PartnerTopicName) {
        $PartnerTopicName = "$Prefix-graph-users-topic"
    }

    if (-not $PartnerEventSubscriptionName) {
        $PartnerEventSubscriptionName = "$Prefix-graph-users-queue-sub"
    }

    if (-not $UserChangesQueueName) {
        $UserChangesQueueName = "graph-user-changes-q"
    }

    if (-not $StorageAccountName) {
        $StorageAccountName = "${Prefix}storage"
    }

    if (-not $GraphAppClientId -or -not $TenantId -or -not $AzureSubscriptionId) {
        Write-Host "Skipping Graph subscription (missing env vars - likely local dev)"
        return
    }

    function Get-GraphToken {
        $maxRetries = 3
        $retryDelay = 2

        $identityEndpoint = $env:IDENTITY_ENDPOINT
        $identityHeader = $env:IDENTITY_HEADER

        if (-not $identityEndpoint -or -not $identityHeader) {
            throw "Managed identity endpoint not available (IDENTITY_ENDPOINT or IDENTITY_HEADER missing)"
        }

        for ($i = 1; $i -le $maxRetries; $i++) {
            try {
                $assertionUri = "$identityEndpoint`?api-version=2019-08-01&resource=api://AzureADTokenExchange&client_id=$UamiClientId"
                $assertionResponse = Invoke-RestMethod -Uri $assertionUri -Headers @{ "X-IDENTITY-HEADER" = $identityHeader } -TimeoutSec 10
                $assertion = $assertionResponse.access_token

                $tokenBody = @{
                    client_id = $GraphAppClientId
                    scope = "https://graph.microsoft.com/.default"
                    client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
                    client_assertion = $assertion
                    grant_type = "client_credentials"
                }

                $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody -TimeoutSec 10
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

    function Get-ArmToken {
        $identityEndpoint = $env:IDENTITY_ENDPOINT
        $identityHeader = $env:IDENTITY_HEADER

        $armUri = "$identityEndpoint`?api-version=2019-08-01&resource=https://management.azure.com/&client_id=$UamiClientId"
        $response = Invoke-RestMethod -Uri $armUri -Headers @{ "X-IDENTITY-HEADER" = $identityHeader } -TimeoutSec 10
        return $response.access_token
    }

    function Ensure-PartnerTopicActivated {
        param(
            [string]$PartnerTopicUrl,
            [hashtable]$ArmHeaders
        )

        try {
            $activateBody = @{ properties = @{ activationState = "Activated" } } | ConvertTo-Json -Depth 3
            Invoke-RestMethod -Uri "$PartnerTopicUrl`?api-version=2024-06-01-preview" -Method PATCH -Headers $ArmHeaders -Body $activateBody | Out-Null
            Write-Host "Partner Topic activated"
        } catch {
            Write-Warning "Partner Topic activation: $_"
        }
    }

    function Ensure-PartnerTopicEventSubscription {
        param(
            [string]$PartnerTopicUrl,
            [hashtable]$ArmHeaders,
            [string]$StorageAccountId
        )

        if (-not $ManagedIdentityResourceId) {
            Write-Warning "MANAGED_IDENTITY_RESOURCE_ID is missing; cannot configure Event Grid delivery identity."
            return
        }

        $eventSubUrl = "$PartnerTopicUrl/eventSubscriptions/$PartnerEventSubscriptionName`?api-version=2024-06-01-preview"

        $eventSubBody = @{
            properties = @{
                deliveryWithResourceIdentity = @{
                    identity = @{
                        type = "UserAssigned"
                        userAssignedIdentity = $ManagedIdentityResourceId
                    }
                    destination = @{
                        endpointType = "StorageQueue"
                        properties = @{
                            resourceId = $StorageAccountId
                            queueName = $UserChangesQueueName
                            queueMessageTimeToLiveInSeconds = 604800
                        }
                    }
                }
                eventDeliverySchema = "CloudEventSchemaV1_0"
            }
        } | ConvertTo-Json -Depth 5

        try {
            $resp = Invoke-RestMethod -Uri $eventSubUrl -Method PUT -Headers $ArmHeaders -Body $eventSubBody -ErrorAction Stop
            Write-Host "Event Subscription ensured on Partner Topic (name: $PartnerEventSubscriptionName)"
            if ($resp) {
                Write-Host "Event Subscription provisioningState: $($resp.properties.provisioningState)"
            }
        } catch {
            $details = $_.Exception.Response | ForEach-Object {
                try {
                    $reader = New-Object IO.StreamReader($_.GetResponseStream())
                    $reader.ReadToEnd()
                } catch { $null }
            }
            Write-Warning "Event Subscription creation failed: $($_.Exception.Message)"
            if ($details) { Write-Warning "Response: $details" }
        }
    }

    function Test-PartnerTopicExists {
        param(
            [string]$PartnerTopicUrl,
            [hashtable]$ArmHeaders
        )

        try {
            Invoke-RestMethod -Uri "$PartnerTopicUrl`?api-version=2024-06-01-preview" -Headers $ArmHeaders -Method GET | Out-Null
            return $true
        } catch {
            return $false
        }
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

    $partnerTopicUrl = "https://management.azure.com/subscriptions/$AzureSubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.EventGrid/partnerTopics/$PartnerTopicName"
    $storageAccountId = "/subscriptions/$AzureSubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
    $expectedNotificationUrl = "EventGrid:?azuresubscriptionid=$AzureSubscriptionId&resourcegroup=$ResourceGroup&partnertopic=$PartnerTopicName&location=$Location"

    $armToken = $null
    $armHeaders = $null
    try {
        $armToken = Get-ArmToken
        $armHeaders = @{
            "Authorization" = "Bearer $armToken"
            "Content-Type" = "application/json"
        }
    } catch {
        Write-Warning "Failed to get ARM token: $_"
    }

    # Check existing subscriptions
    $ourSubscription = $null
    try {
        $existingSubscriptions = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions" -Headers $headers
        Write-Host "Found $($existingSubscriptions.value.Count) existing Graph subscription(s)"

        $ourSubscription = $existingSubscriptions.value | Where-Object {
            $_.resource -eq "users" -and $_.notificationUrl -match "partnertopic=$PartnerTopicName"
        } | Select-Object -First 1

        if ($ourSubscription) {
            $expirationTime = [DateTime]::Parse($ourSubscription.expirationDateTime)
            $hoursRemaining = ($expirationTime - (Get-Date).ToUniversalTime()).TotalHours
            Write-Host "Existing users subscription found (ID: $($ourSubscription.id)), expires in $([Math]::Round($hoursRemaining, 1)) hours"
            Write-Host "Subscription details:"
            Write-Host "  Resource: $($ourSubscription.resource)"
            Write-Host "  ChangeType: $($ourSubscription.changeType)"
            Write-Host "  NotificationUrl: $($ourSubscription.notificationUrl)"
            Write-Host "  LifecycleNotificationUrl: $($ourSubscription.lifecycleNotificationUrl)"
            Write-Host "  Expiration: $($ourSubscription.expirationDateTime)"
            Write-Host "  ClientState set: $([string]::IsNullOrEmpty($ourSubscription.clientState) -eq $false)"

            if ($ourSubscription.notificationUrl -ne $expectedNotificationUrl) {
                Write-Warning "Subscription notificationUrl does not match expected target. Recreating subscription."
                Write-Host "  Expected: $expectedNotificationUrl"
                try {
                    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions/$($ourSubscription.id)" `
                        -Method DELETE -Headers $headers | Out-Null
                    Write-Host "Deleted mismatched subscription: $($ourSubscription.id)"
                    $ourSubscription = $null
                } catch {
                    Write-Warning "Failed to delete mismatched subscription: $_"
                }
            }

            if ($ourSubscription -and $armHeaders -and -not (Test-PartnerTopicExists -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders)) {
                Write-Warning "Partner topic not found for existing subscription. Recreating subscription."
                try {
                    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions/$($ourSubscription.id)" `
                        -Method DELETE -Headers $headers | Out-Null
                    Write-Host "Deleted subscription to force partner topic creation: $($ourSubscription.id)"
                    $ourSubscription = $null
                } catch {
                    Write-Warning "Failed to delete subscription: $_"
                }
            }

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

    if (-not $ourSubscription) {
        Write-Host "No Graph subscription found, creating..."

        $notificationUrl = $expectedNotificationUrl
        $expirationDateTime = (Get-Date).ToUniversalTime().AddDays(2).ToString("yyyy-MM-ddTHH:mm:ssZ")

        $subscriptionBody = @{
            changeType = "created,updated,deleted"
            notificationUrl = $notificationUrl
            lifecycleNotificationUrl = $notificationUrl
            resource = "users"
            expirationDateTime = $expirationDateTime
            clientState = "$Prefix-secret-state"
        } | ConvertTo-Json

        try {
            $newSubscription = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions" `
                -Method POST -Headers $headers -Body $subscriptionBody
            Write-Host "Graph subscription created: $($newSubscription.id)"

            if ($armHeaders) {
                $maxPartnerRetries = 5
                $partnerDelay = 5
                for ($attempt = 1; $attempt -le $maxPartnerRetries; $attempt++) {
                    if (Test-PartnerTopicExists -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders) {
                        Ensure-PartnerTopicActivated -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders
                        Ensure-PartnerTopicEventSubscription -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders -StorageAccountId $storageAccountId
                        break
                    }
                    Write-Host "Partner topic not visible yet. Retry $attempt/$maxPartnerRetries in ${partnerDelay}s..."
                    Start-Sleep -Seconds $partnerDelay
                    $partnerDelay *= 2
                }
            }
        } catch {
            Write-Warning "Graph subscription creation: $_"
        }
    } elseif ($armHeaders) {
        Ensure-PartnerTopicEventSubscription -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders -StorageAccountId $storageAccountId
        Ensure-PartnerTopicActivated -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders
    }
}
