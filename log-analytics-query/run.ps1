using namespace System.Net

param($Request, $outputDocument)

function New-HttpResponse {
    param([int]$StatusCode, $Body)
    $json = $Body | ConvertTo-Json -Depth 10
    return @{
        StatusCode = $StatusCode
        Body = $json
        Headers = @{ "Content-Type" = "application/json" }
    }
}

function Get-LogToken {
    $tenantId = $env:AZURE_TENANT_ID
    $uamiClientId = $env:AzureWebJobsStorage__clientId
    $identityEndpoint = $env:IDENTITY_ENDPOINT
    $identityHeader = $env:IDENTITY_HEADER
    if (-not $tenantId -or -not $uamiClientId -or -not $identityEndpoint -or -not $identityHeader) {
        throw "Missing managed identity environment variables."
    }

    $assertionUri = "$identityEndpoint`?api-version=2019-08-01&resource=api://AzureADTokenExchange&client_id=$uamiClientId"
    $assertionResponse = Invoke-RestMethod -Uri $assertionUri -Headers @{ "X-IDENTITY-HEADER" = $identityHeader } -ErrorAction Stop
    $assertion = $assertionResponse.access_token

    $tokenBody = @{
        client_id             = $env:GRAPH_APP_CLIENT_ID
        scope                 = "https://api.loganalytics.io/.default"
        client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        client_assertion      = $assertion
        grant_type            = "client_credentials"
    }

    $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody -ErrorAction Stop
    return $tokenResponse.access_token
}

function Invoke-LogQuery {
    param(
        [string]$WorkspaceId,
        [string]$Query,
        [string]$TimeSpan,
        [string]$AccessToken
    )

    $uri = "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query"
    $body = @{ query = $Query }
    if ($TimeSpan) { $body.timespan = $TimeSpan }

    return Invoke-RestMethod -Uri $uri -Method POST -Headers @{ Authorization = "Bearer $AccessToken" } -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
}

try {
    $workspaceId = $env:LOG_QUERY_WORKSPACE_ID
    $defaultQuery = $env:LOG_QUERY_KQL
    $defaultTimeSpan = $env:LOG_QUERY_TIMESPAN

    $body = $null
    if ($Request -and $Request.Body -and ($Request.Body -isnot [string])) {
        $body = $Request.Body
    } elseif ($Request -and $Request.Body) {
        $body = $Request.Body | ConvertFrom-Json
    }

    $query = $body.query
    $timeSpan = $body.timeSpan

    if (-not $query) { $query = $defaultQuery }
    if (-not $timeSpan) { $timeSpan = $defaultTimeSpan }

    if (-not $workspaceId -or -not $query) {
        $missing = @()
        if (-not $workspaceId) { $missing += "LOG_QUERY_WORKSPACE_ID" }
        if (-not $query) { $missing += "LOG_QUERY_KQL" }
        $resp = New-HttpResponse -StatusCode 400 -Body @{ error = "Missing configuration"; missing = $missing }
        Push-OutputBinding -Name Response -Value $resp
        return
    }

    $accessToken = Get-LogToken
    $logResult = Invoke-LogQuery -WorkspaceId $workspaceId -Query $query -TimeSpan $timeSpan -AccessToken $accessToken

    $tables = @()
    foreach ($t in $logResult.tables) {
        $rows = @()
        $columns = $t.columns.name
        foreach ($row in $t.rows) {
            $obj = [ordered]@{}
            for ($i = 0; $i -lt $columns.Count; $i++) {
                $obj[$columns[$i]] = $row[$i]
            }
            $rows += $obj
        }
        $tables += @{
            name = $t.name
            columns = $t.columns
            rows = $rows
            rowCount = $rows.Count
        }
    }

    $runId = [guid]::NewGuid().ToString()
    $doc = @{
        id = $runId
        pk = "log-query"
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        workspaceId = $workspaceId
        query = $query
        timeSpan = $timeSpan
        tables = $tables
    }

    Push-OutputBinding -Name outputDocument -Value $doc

    $respBody = @{
        runId = $runId
        tables = $tables | ForEach-Object { @{ name = $_.name; rowCount = $_.rowCount } }
    }
    $resp = New-HttpResponse -StatusCode 200 -Body $respBody
    Push-OutputBinding -Name Response -Value $resp
} catch {
    $resp = New-HttpResponse -StatusCode 500 -Body @{ error = $_.Exception.Message }
    Push-OutputBinding -Name Response -Value $resp
    throw
}
