# shared/graph-subscription.ps1
# Shared helper to ensure Microsoft Graph change notification subscription and Event Grid wiring

function Ensure-GraphChangeSubscription {
    [CmdletBinding()]
    param(
        [string]$Prefix = $env:PREFIX,
        [string]$ResourceGroup = $env:RESOURCE_GROUP,
        [string]$Location = $env:LOCATION,
        [string]$GraphAppClientId = $env:GRAPH_APP_CLIENT_ID,
        [string]$TenantId = $env:AZURE_TENANT_ID,
        [string]$AzureSubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
        [string]$UamiClientId = $env:AzureWebJobsStorage__clientId,
        [string]$ManagedIdentityResourceId = $env:MANAGED_IDENTITY_RESOURCE_ID,
        [string]$StorageAccountName = $env:AzureWebJobsStorage__accountName,
        [string]$PartnerTopicName = $env:GRAPH_PARTNER_TOPIC_NAME,
        [string]$PartnerEventSubscriptionName = $env:GRAPH_PARTNER_EVENT_SUB_NAME,
        [string]$UserChangesQueueName = $env:GRAPH_USER_CHANGES_QUEUE_NAME,
        [string]$GraphResource = $env:GRAPH_RESOURCE,
        [string]$GraphChangeType = $env:GRAPH_CHANGE_TYPE,
        [string]$GraphClientState = $env:GRAPH_CLIENT_STATE
    )

    $UrlTemplates = @{
        GraphSubscriptionsUrl = "https://graph.microsoft.com/v1.0/subscriptions"
        GraphTokenUrlTemplate = "https://login.microsoftonline.com/{0}/oauth2/v2.0/token"
        GraphSubscriptionUrlTemplate = "https://graph.microsoft.com/v1.0/subscriptions/{0}"
        ArmPartnerTopicUrlTemplate = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.EventGrid/partnerTopics/{2}"
        ArmStorageAccountIdTemplate = "/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Storage/storageAccounts/{2}"
        IdentityTokenUriTemplate = "{0}?api-version={1}&resource={2}&client_id={3}"
        PartnerTopicApiQueryTemplate = "{0}?api-version={1}"
        NotificationUrlTemplate = "EventGrid:?azuresubscriptionid={0}&resourcegroup={1}&partnertopic={2}&location={3}"
        PartnerTopicMatchTemplate = "partnertopic={0}"
        PartnerTopicEventSubUrlTemplate = "{0}/eventSubscriptions/{1}?api-version={2}"
    }

    $ApiConfigs = @{
        ErrorActionStop = "Stop"
        HeaderAuthorization = "Authorization"
        HeaderContentType = "Content-Type"
        HeaderIdentity = "X-IDENTITY-HEADER"
        ContentTypeJson = "application/json"
        BearerFormat = "Bearer {0}"
        MethodGet = "GET"
        MethodPost = "POST"
        MethodPatch = "PATCH"
        MethodPut = "PUT"
        MethodDelete = "DELETE"
        IdentityApiVersion = "2019-08-01"
        PartnerTopicApiVersion = "2024-06-01-preview"
        EventSubscriptionApiVersion = "2025-07-15-preview"
        ArmResource = "https://management.azure.com/"
        GraphExchangeResource = "api://AzureADTokenExchange"
        GraphScope = "https://graph.microsoft.com/.default"
        AssertionTypeJwtBearer = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        GrantTypeClientCredentials = "client_credentials"
        DateTimeFormatUtc = "yyyy-MM-ddTHH:mm:ssZ"
        QueueMessageTtlSeconds = 604800
        MaxGraphTokenRetries = 3
        GraphTokenRetryDelaySeconds = 2
        MaxEventSubAttempts = 4
        EventSubInitialDelaySeconds = 5
        MaxPartnerRetries = 5
        PartnerRetryDelaySeconds = 5
    }

    $Messages = @{
        IdentityHeaderMissingMessage = "Managed identity endpoint not available (IDENTITY_ENDPOINT or IDENTITY_HEADER missing)"
        MissingSettingsMessage = "Skipping Graph subscription (missing required app settings)"
        GraphTokenFailureMessage = "Failed to get Graph token: {0} - subscription management skipped"
        ArmTokenFailureMessage = "Failed to get ARM token: {0}"
        PartnerTopicActivatedMessage = "Partner Topic activated"
        PartnerTopicActivationWarning = "Partner Topic activation: {0}"
        EventSubscriptionStateMessage = "Event Subscription current state: {0}"
        EventSubscriptionSucceededMessage = "Event Subscription already provisioned. Skipping create/update."
        EventSubscriptionCreatingMessage = "Event Subscription is still provisioning. Skipping update; try again later."
        EventSubscriptionFailedWarning = "Event Subscription is in Failed state. Deleting to allow re-create."
        EventSubscriptionDeleteFailedWarning = "Failed to delete existing event subscription: {0}"
        EventSubscriptionEnsuredMessage = "Event Subscription ensured on Partner Topic (name: {0})"
        EventSubscriptionProvisioningStateMessage = "Event Subscription provisioningState: {0}"
        EventSubscriptionCreateFailedWarning = "Event Subscription creation failed (attempt {0}/{1}): {2}"
        EventSubscriptionStatusCodeWarning = "Event Subscription status code: {0}"
        EventSubscriptionErrorBodyWarning = "Event Subscription error body: {0}"
        EventSubscriptionCreateFailedFinalWarning = "Event Subscription creation failed after {0} attempts. Continuing without throwing."
        GraphTokenSuccessMessage = "Got Graph API token"
        ExistingGraphSubscriptionsMessage = "Found {0} existing Graph subscription(s)"
        ExistingUsersSubscriptionMessage = "Existing users subscription found (ID: {0}), expires in {1} hours"
        SubscriptionDetailsHeader = "Subscription details:"
        SubscriptionDetailResource = "  Resource: {0}"
        SubscriptionDetailChangeType = "  ChangeType: {0}"
        SubscriptionDetailNotificationUrl = "  NotificationUrl: {0}"
        SubscriptionDetailLifecycleUrl = "  LifecycleNotificationUrl: {0}"
        SubscriptionDetailExpiration = "  Expiration: {0}"
        SubscriptionDetailClientState = "  ClientState set: {0}"
        NotificationUrlMismatchWarning = "Subscription notificationUrl does not match expected target. Recreating subscription."
        ExpectedNotificationUrlMessage = "  Expected: {0}"
        SubscriptionDeletedMessage = "Deleted mismatched subscription: {0}"
        SubscriptionDeleteFailedWarning = "Failed to delete mismatched subscription: {0}"
        PartnerTopicMissingWarning = "Partner topic not found for existing subscription. Recreating subscription."
        SubscriptionDeletedForPartnerTopicMessage = "Deleted subscription to force partner topic creation: {0}"
        SubscriptionDeleteForPartnerTopicFailedWarning = "Failed to delete subscription: {0}"
        RenewingSubscriptionMessage = "Renewing subscription..."
        SubscriptionRenewedMessage = "Subscription renewed"
        SubscriptionCheckErrorWarning = "Error checking subscriptions: {0}"
        NoSubscriptionMessage = "No Graph subscription found, creating..."
        GraphSubscriptionCreatedMessage = "Graph subscription created: {0}"
        PartnerTopicNotVisibleMessage = "Partner topic not visible yet. Retry {0}/{1} in {2}s..."
        GraphSubscriptionCreateWarning = "Graph subscription creation: {0}"
    }

    $AzureStatics = @{
        IdentityTypeUserAssigned = "UserAssigned"
        EventDeliverySchema = "CloudEventSchemaV1_0"
        StorageQueueEndpointType = "StorageQueue"
        ProvisioningStateSucceeded = "Succeeded"
        ProvisioningStateCreating = "Creating"
        ProvisioningStateFailed = "Failed"
        ActivationState = "Activated"
    }

    $ErrorActionPreference = $ApiConfigs.ErrorActionStop

    if (
        -not $GraphAppClientId -or
        -not $TenantId -or
        -not $AzureSubscriptionId -or
        -not $UamiClientId -or
        -not $ManagedIdentityResourceId -or
        -not $StorageAccountName -or
        -not $PartnerTopicName -or
        -not $PartnerEventSubscriptionName -or
        -not $UserChangesQueueName -or
        -not $ResourceGroup -or
        -not $Location -or
        -not $Prefix -or
        -not $GraphResource -or
        -not $GraphChangeType -or
        -not $GraphClientState
    ) {
        Write-Host $Messages.MissingSettingsMessage
        return
    }

    function Get-GraphToken {
        $maxRetries = $ApiConfigs.MaxGraphTokenRetries
        $retryDelay = $ApiConfigs.GraphTokenRetryDelaySeconds

        $identityEndpoint = $env:IDENTITY_ENDPOINT
        $identityHeader = $env:IDENTITY_HEADER

        if (-not $identityEndpoint -or -not $identityHeader) {
            throw $Messages.IdentityHeaderMissingMessage
        }

        for ($i = 1; $i -le $maxRetries; $i++) {
            try {
                $assertionUri = [string]::Format(
                    $UrlTemplates.IdentityTokenUriTemplate,
                    $identityEndpoint,
                    $ApiConfigs.IdentityApiVersion,
                    $ApiConfigs.GraphExchangeResource,
                    $UamiClientId
                )
                $assertionResponse = Invoke-RestMethod -Uri $assertionUri -Headers @{ $ApiConfigs.HeaderIdentity = $identityHeader } -TimeoutSec 10
                $assertion = $assertionResponse.access_token

                $tokenBody = @{
                    client_id = $GraphAppClientId
                    scope = $ApiConfigs.GraphScope
                    client_assertion_type = $ApiConfigs.AssertionTypeJwtBearer
                    client_assertion = $assertion
                    grant_type = $ApiConfigs.GrantTypeClientCredentials
                }

                $tokenUrl = [string]::Format($UrlTemplates.GraphTokenUrlTemplate, $TenantId)
                $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method $ApiConfigs.MethodPost -Body $tokenBody -TimeoutSec 10
                return $tokenResponse.access_token
            } catch {
                if ($i -lt $maxRetries) {
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

        $armUri = [string]::Format(
            $UrlTemplates.IdentityTokenUriTemplate,
            $identityEndpoint,
            $ApiConfigs.IdentityApiVersion,
            $ApiConfigs.ArmResource,
            $UamiClientId
        )
        $response = Invoke-RestMethod -Uri $armUri -Headers @{ $ApiConfigs.HeaderIdentity = $identityHeader } -TimeoutSec 10
        return $response.access_token
    }

    function Ensure-PartnerTopicActivated {
        param(
            [string]$PartnerTopicUrl,
            [hashtable]$ArmHeaders
        )

        try {
            $activateBody = @{ properties = @{ activationState = $AzureStatics.ActivationState } } | ConvertTo-Json -Depth 3
            $partnerTopicQueryUrl = [string]::Format($UrlTemplates.PartnerTopicApiQueryTemplate, $PartnerTopicUrl, $ApiConfigs.PartnerTopicApiVersion)
            Invoke-RestMethod -Uri $partnerTopicQueryUrl -Method $ApiConfigs.MethodPatch -Headers $ArmHeaders -Body $activateBody | Out-Null
            Write-Host $Messages.PartnerTopicActivatedMessage
        } catch {
            Write-Warning ([string]::Format($Messages.PartnerTopicActivationWarning, $_))
        }
    }

    function Ensure-PartnerTopicEventSubscription {
        param(
            [string]$PartnerTopicUrl,
            [hashtable]$ArmHeaders,
            [string]$StorageAccountId
        )

        $eventSubUrl = [string]::Format(
            $UrlTemplates.PartnerTopicEventSubUrlTemplate,
            $PartnerTopicUrl,
            $PartnerEventSubscriptionName,
            $ApiConfigs.EventSubscriptionApiVersion
        )

        $existingSub = $null
        try {
            $existingSub = Invoke-RestMethod -Uri $eventSubUrl -Method $ApiConfigs.MethodGet -Headers $ArmHeaders -ErrorAction $ApiConfigs.ErrorActionStop
        } catch {
            $existingSub = $null
        }

        if ($existingSub) {
            $state = $existingSub.properties.provisioningState
            Write-Host ([string]::Format($Messages.EventSubscriptionStateMessage, $state))

            if ($state -eq $AzureStatics.ProvisioningStateSucceeded) {
                Write-Host $Messages.EventSubscriptionSucceededMessage
                return
            }

            if ($state -eq $AzureStatics.ProvisioningStateCreating) {
                Write-Host $Messages.EventSubscriptionCreatingMessage
                return
            }

            if ($state -eq $AzureStatics.ProvisioningStateFailed) {
                Write-Warning $Messages.EventSubscriptionFailedWarning
                try {
                    Invoke-RestMethod -Uri $eventSubUrl -Method $ApiConfigs.MethodDelete -Headers $ArmHeaders -ErrorAction $ApiConfigs.ErrorActionStop | Out-Null
                    Start-Sleep -Seconds 5
                } catch {
                    Write-Warning ([string]::Format($Messages.EventSubscriptionDeleteFailedWarning, $_))
                    return
                }
            }
        }

        $eventSubBody = @{
            properties = @{
                destination = @{
                    endpointType = $AzureStatics.StorageQueueEndpointType
                    properties = @{
                        resourceId = $StorageAccountId
                        queueName = $UserChangesQueueName
                        queueMessageTimeToLiveInSeconds = $ApiConfigs.QueueMessageTtlSeconds
                    }
                }
                eventDeliverySchema = $AzureStatics.EventDeliverySchema
            }
        } | ConvertTo-Json -Depth 5

        $maxAttempts = $ApiConfigs.MaxEventSubAttempts
        $delaySeconds = $ApiConfigs.EventSubInitialDelaySeconds
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                $resp = Invoke-RestMethod -Uri $eventSubUrl -Method $ApiConfigs.MethodPut -Headers $ArmHeaders -Body $eventSubBody -ErrorAction $ApiConfigs.ErrorActionStop
                Write-Host ([string]::Format($Messages.EventSubscriptionEnsuredMessage, $PartnerEventSubscriptionName))
                if ($resp) {
                    Write-Host ([string]::Format($Messages.EventSubscriptionProvisioningStateMessage, $resp.properties.provisioningState))
                }
                return
            } catch {
                $errorMessage = $_.Exception.Message
                $responseBody = $null
                $statusCode = $null

                try {
                    if ($_.Exception -and $_.Exception.Response) {
                        $statusCode = $_.Exception.Response.StatusCode.value__
                        if ($_.Exception.Response.GetResponseStream()) {
                            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                            $responseBody = $reader.ReadToEnd()
                            $reader.Close()
                        }
                    }
                } catch {
                    $responseBody = $null
                }

                if (-not $responseBody -and $_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $responseBody = $_.ErrorDetails.Message
                }

                Write-Warning ([string]::Format($Messages.EventSubscriptionCreateFailedWarning, $attempt, $maxAttempts, $errorMessage))
                if ($statusCode) {
                    Write-Warning ([string]::Format($Messages.EventSubscriptionStatusCodeWarning, $statusCode))
                }
                if ($responseBody) {
                    Write-Warning ([string]::Format($Messages.EventSubscriptionErrorBodyWarning, $responseBody))
                }

                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Seconds $delaySeconds
                    $delaySeconds *= 2
                } else {
                    Write-Warning ([string]::Format($Messages.EventSubscriptionCreateFailedFinalWarning, $maxAttempts))
                    return
                }
            }
        }
    }

    function Test-PartnerTopicExists {
        param(
            [string]$PartnerTopicUrl,
            [hashtable]$ArmHeaders
        )

        try {
            $partnerTopicQueryUrl = [string]::Format($UrlTemplates.PartnerTopicApiQueryTemplate, $PartnerTopicUrl, $ApiConfigs.PartnerTopicApiVersion)
            Invoke-RestMethod -Uri $partnerTopicQueryUrl -Headers $ArmHeaders -Method $ApiConfigs.MethodGet | Out-Null
            return $true
        } catch {
            return $false
        }
    }

    try {
        $graphToken = Get-GraphToken
        Write-Host $Messages.GraphTokenSuccessMessage
    } catch {
        Write-Warning ([string]::Format($Messages.GraphTokenFailureMessage, $_))
        return
    }

    $headers = @{
        $ApiConfigs.HeaderAuthorization = [string]::Format($ApiConfigs.BearerFormat, $graphToken)
        $ApiConfigs.HeaderContentType = $ApiConfigs.ContentTypeJson
    }

    $partnerTopicUrl = [string]::Format($UrlTemplates.ArmPartnerTopicUrlTemplate, $AzureSubscriptionId, $ResourceGroup, $PartnerTopicName)
    $storageAccountId = [string]::Format($UrlTemplates.ArmStorageAccountIdTemplate, $AzureSubscriptionId, $ResourceGroup, $StorageAccountName)
    $expectedNotificationUrl = [string]::Format($UrlTemplates.NotificationUrlTemplate, $AzureSubscriptionId, $ResourceGroup, $PartnerTopicName, $Location)

    $armToken = $null
    $armHeaders = $null
    try {
        $armToken = Get-ArmToken
        $armHeaders = @{
            $ApiConfigs.HeaderAuthorization = [string]::Format($ApiConfigs.BearerFormat, $armToken)
            $ApiConfigs.HeaderContentType = $ApiConfigs.ContentTypeJson
        }
    } catch {
        Write-Warning ([string]::Format($Messages.ArmTokenFailureMessage, $_))
    }

    # Check existing subscriptions
    $ourSubscription = $null
    try {
        $existingSubscriptions = Invoke-RestMethod -Uri $UrlTemplates.GraphSubscriptionsUrl -Headers $headers
        Write-Host ([string]::Format($Messages.ExistingGraphSubscriptionsMessage, $existingSubscriptions.value.Count))

        $partnerTopicMatch = [string]::Format($UrlTemplates.PartnerTopicMatchTemplate, $PartnerTopicName)
        $ourSubscription = $existingSubscriptions.value | Where-Object {
            $_.resource -eq $GraphResource -and $_.notificationUrl -match $partnerTopicMatch
        } | Select-Object -First 1

        if ($ourSubscription) {
            $expirationTime = [DateTime]::Parse($ourSubscription.expirationDateTime)
            $hoursRemaining = ($expirationTime - (Get-Date).ToUniversalTime()).TotalHours
            $subscriptionUrl = [string]::Format($UrlTemplates.GraphSubscriptionUrlTemplate, $ourSubscription.id)
            Write-Host ([string]::Format($Messages.ExistingUsersSubscriptionMessage, $ourSubscription.id, [Math]::Round($hoursRemaining, 1)))
            Write-Host $Messages.SubscriptionDetailsHeader
            Write-Host ([string]::Format($Messages.SubscriptionDetailResource, $ourSubscription.resource))
            Write-Host ([string]::Format($Messages.SubscriptionDetailChangeType, $ourSubscription.changeType))
            Write-Host ([string]::Format($Messages.SubscriptionDetailNotificationUrl, $ourSubscription.notificationUrl))
            Write-Host ([string]::Format($Messages.SubscriptionDetailLifecycleUrl, $ourSubscription.lifecycleNotificationUrl))
            Write-Host ([string]::Format($Messages.SubscriptionDetailExpiration, $ourSubscription.expirationDateTime))
            Write-Host ([string]::Format($Messages.SubscriptionDetailClientState, ([string]::IsNullOrEmpty($ourSubscription.clientState) -eq $false)))

            if ($ourSubscription.notificationUrl -ne $expectedNotificationUrl) {
                Write-Warning $Messages.NotificationUrlMismatchWarning
                Write-Host ([string]::Format($Messages.ExpectedNotificationUrlMessage, $expectedNotificationUrl))
                try {
                    Invoke-RestMethod -Uri $subscriptionUrl `
                        -Method $ApiConfigs.MethodDelete -Headers $headers | Out-Null
                    Write-Host ([string]::Format($Messages.SubscriptionDeletedMessage, $ourSubscription.id))
                    $ourSubscription = $null
                } catch {
                    Write-Warning ([string]::Format($Messages.SubscriptionDeleteFailedWarning, $_))
                }
            }

            if ($ourSubscription -and $armHeaders -and -not (Test-PartnerTopicExists -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders)) {
                Write-Warning $Messages.PartnerTopicMissingWarning
                try {
                    Invoke-RestMethod -Uri $subscriptionUrl `
                        -Method $ApiConfigs.MethodDelete -Headers $headers | Out-Null
                    Write-Host ([string]::Format($Messages.SubscriptionDeletedForPartnerTopicMessage, $ourSubscription.id))
                    $ourSubscription = $null
                } catch {
                    Write-Warning ([string]::Format($Messages.SubscriptionDeleteForPartnerTopicFailedWarning, $_))
                }
            }

            if ($hoursRemaining -lt 12) {
                Write-Host $Messages.RenewingSubscriptionMessage
                $newExpiration = (Get-Date).ToUniversalTime().AddDays(2).ToString($ApiConfigs.DateTimeFormatUtc)
                $renewBody = @{ expirationDateTime = $newExpiration } | ConvertTo-Json
                Invoke-RestMethod -Uri $subscriptionUrl `
                    -Method $ApiConfigs.MethodPatch -Headers $headers -Body $renewBody | Out-Null
                Write-Host $Messages.SubscriptionRenewedMessage
            }
        }
    } catch {
        Write-Warning ([string]::Format($Messages.SubscriptionCheckErrorWarning, $_))
    }

    if (-not $ourSubscription) {
        Write-Host $Messages.NoSubscriptionMessage

        $notificationUrl = $expectedNotificationUrl
        $expirationDateTime = (Get-Date).ToUniversalTime().AddDays(2).ToString($ApiConfigs.DateTimeFormatUtc)

        $subscriptionBody = @{
            changeType = $GraphChangeType
            notificationUrl = $notificationUrl
            lifecycleNotificationUrl = $notificationUrl
            resource = $GraphResource
            expirationDateTime = $expirationDateTime
            clientState = $GraphClientState
        } | ConvertTo-Json

        try {
            $newSubscription = Invoke-RestMethod -Uri $UrlTemplates.GraphSubscriptionsUrl `
                -Method $ApiConfigs.MethodPost -Headers $headers -Body $subscriptionBody
            Write-Host ([string]::Format($Messages.GraphSubscriptionCreatedMessage, $newSubscription.id))

            if ($armHeaders) {
                $maxPartnerRetries = $ApiConfigs.MaxPartnerRetries
                $partnerDelay = $ApiConfigs.PartnerRetryDelaySeconds
                for ($attempt = 1; $attempt -le $maxPartnerRetries; $attempt++) {
                    if (Test-PartnerTopicExists -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders) {
                        Ensure-PartnerTopicActivated -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders
                        Ensure-PartnerTopicEventSubscription -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders -StorageAccountId $storageAccountId
                        break
                    }
                    Write-Host ([string]::Format($Messages.PartnerTopicNotVisibleMessage, $attempt, $maxPartnerRetries, $partnerDelay))
                    Start-Sleep -Seconds $partnerDelay
                    $partnerDelay *= 2
                }
            }
        } catch {
            Write-Warning ([string]::Format($Messages.GraphSubscriptionCreateWarning, $_))
        }
    } elseif ($armHeaders) {
        Ensure-PartnerTopicActivated -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders
        Ensure-PartnerTopicEventSubscription -PartnerTopicUrl $partnerTopicUrl -ArmHeaders $armHeaders -StorageAccountId $storageAccountId
    }
}
