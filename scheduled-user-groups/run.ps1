using namespace System.Net

param($Timer, $Request)

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

function Get-UsersToQuery {
    param($Request)
    $users = @()
    if ($Request) {
        $override = $null
        if ($Request.Query.userId) { $override = $Request.Query.userId }
        elseif ($Request.Body) {
            try {
                $body = if ($Request.Body -is [string]) { $Request.Body | ConvertFrom-Json -ErrorAction Stop } else { $Request.Body }
                if ($body.userId) { $override = $body.userId }
            } catch { }
        }
        if ($override) {
            $users = @($override)
            return $users
        }
    }

    $usersSetting = $env:GRAPH_GROUP_QUERY_USERS
    if ($usersSetting) {
        $users = $usersSetting -split '[,; ]' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }
    }
    return $users
}

try {
    $users = Get-UsersToQuery -Request $Request
    if (-not $users -or $users.Count -eq 0) {
        Write-Warning "No users configured or provided; skipping run."
        if ($Request) {
            $resp = @{
                StatusCode = 400
                Body = @{ error = "No users specified. Set GRAPH_GROUP_QUERY_USERS or pass userId." } | ConvertTo-Json
                Headers = @{ "Content-Type" = "application/json" }
            }
            Push-OutputBinding -Name Response -Value $resp
        }
        return
    }

    $accessToken = Get-GraphToken
    $runId = [guid]::NewGuid().ToString()
    $timestamp = (Get-Date).ToUniversalTime().ToString("o")
    $results = @()

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
            $results += @{
                user = $user
                totalGroups = $groupSummaries.Count
            }
        } catch {
            Write-Warning "Failed to process user '$user': $_"
            $results += @{
                user = $user
                error = $_.Exception.Message
            }
        }
    }

    if ($Request) {
        $resp = @{
            StatusCode = 200
            Body = (@{ runId = $runId; timestamp = $timestamp; results = $results } | ConvertTo-Json -Depth 6)
            Headers = @{ "Content-Type" = "application/json" }
        }
        Push-OutputBinding -Name Response -Value $resp
    }
} catch {
    Write-Error "Group query failed: $_"
    if ($Request) {
        $resp = @{
            StatusCode = 500
            Body = @{ error = $_.Exception.Message } | ConvertTo-Json
            Headers = @{ "Content-Type" = "application/json" }
        }
        Push-OutputBinding -Name Response -Value $resp
    }
    throw
}
