using namespace System.Net

param($Timer)

function Get-GraphToken {
    $graphAppClientId = $env:GRAPH_APP_CLIENT_ID
    $tenantId = $env:AZURE_TENANT_ID
    $uamiClientId = $env:AzureWebJobsStorage__clientId
    $identityEndpoint = $env:IDENTITY_ENDPOINT
    $identityHeader = $env:IDENTITY_HEADER

    if (-not $graphAppClientId -or -not $tenantId -or -not $identityEndpoint -or -not $uamiClientId) {
        throw "Missing Graph or Managed Identity configuration."
    }

    $assertionUri = "$identityEndpoint`?api-version=2019-08-01&resource=api://AzureADTokenExchange&client_id=$uamiClientId"
    $assertionResponse = Invoke-RestMethod -Uri $assertionUri -Headers @{ "X-IDENTITY-HEADER" = $identityHeader }
    $assertion = $assertionResponse.access_token

    $tokenBody = @{
        client_id             = $graphAppClientId
        scope                 = "https://graph.microsoft.com/.default"
        client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        client_assertion      = $assertion
        grant_type            = "client_credentials"
    }

    $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody
    return $tokenResponse.access_token
}

function Get-UserGroups {
    param(
        [string]$UserIdOrUpn,
        [string]$AccessToken
    )

    $groups = @()
    $uri = "https://graph.microsoft.com/v1.0/users/$UserIdOrUpn/memberOf?`$select=id,displayName,description,mail,securityEnabled,groupTypes"

    while ($uri) {
        $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $AccessToken" } -ErrorAction Stop
        if ($response.value) {
            $groups += $response.value
        }
        $uri = $response.'@odata.nextLink'
    }

    return $groups
}

try {
    $usersSetting = $env:GRAPH_GROUP_QUERY_USERS
    if (-not $usersSetting) {
        Write-Warning "GRAPH_GROUP_QUERY_USERS is not set; skipping run."
        return
    }

    $users = $usersSetting -split '[,; ]' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }
    if (-not $users -or $users.Count -eq 0) {
        Write-Warning "GRAPH_GROUP_QUERY_USERS contains no entries; skipping run."
        return
    }

    $accessToken = Get-GraphToken
    $runId = [guid]::NewGuid().ToString()
    $timestamp = (Get-Date).ToUniversalTime().ToString("o")

    foreach ($user in $users) {
        try {
            Write-Host "Querying groups for user '$user'..."
            $groups = Get-UserGroups -UserIdOrUpn $user -AccessToken $accessToken
            $groupSummaries = @(
                $groups | ForEach-Object {
                    @{
                        id = $_.id
                        displayName = $_.displayName
                        description = $_.description
                        mail = $_.mail
                        securityEnabled = $_.securityEnabled
                        groupTypes = $_.groupTypes
                    }
                }
            )

            $payload = @{
                runId = $runId
                timestamp = $timestamp
                user = $user
                totalGroups = $groupSummaries.Count
                groups = $groupSummaries
            }

            Push-OutputBinding -Name groupQueue -Value ($payload | ConvertTo-Json -Depth 6)
            Write-Host "Enqueued $($groupSummaries.Count) groups for user '$user'."
        } catch {
            Write-Warning "Failed to process user '$user': $_"
        }
    }
} catch {
    Write-Error "Scheduled group query failed: $_"
    throw
}
