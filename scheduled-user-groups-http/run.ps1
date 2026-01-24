using namespace System.Net

param($Request)

$scheduledScript = Join-Path $PSScriptRoot ".." "scheduled-user-groups" "run.ps1"

try {
    & $scheduledScript -Request $Request -Timer $null
} catch {
    $resp = @{
        StatusCode = 500
        Body = (@{ error = $_.Exception.Message } | ConvertTo-Json)
        Headers = @{ "Content-Type" = "application/json" }
    }
    Push-OutputBinding -Name Response -Value $resp
    throw
}
