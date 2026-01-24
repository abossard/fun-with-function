# profile.ps1
# Runs on cold start - manages Microsoft Graph change notification subscription
# Creates/renews subscription, activates Partner Topic, creates Event Subscription

$ErrorActionPreference = "Stop"

Write-Host "=== PowerShell Function App Cold Start ==="
Write-Host "Initializing Graph subscription..."

$sharedScript = Join-Path $PSScriptRoot "shared/graph-subscription.ps1"
if (Test-Path $sharedScript) {
    . $sharedScript
    try {
        Ensure-GraphChangeSubscription
    } catch {
        Write-Warning "Graph subscription setup failed: $_"
    }
} else {
    Write-Warning "Shared helper not found: $sharedScript"
}

Write-Host "=== Cold Start Complete ==="
