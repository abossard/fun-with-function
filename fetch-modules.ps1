param(
    [string]$ModulePath = "modules",
    [string[]]$Modules = @("Az.Accounts", "Az.Storage", "Az.CosmosDB")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ModulePath)) {
    New-Item -ItemType Directory -Path $ModulePath -Force | Out-Null
}

try {
    Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction SilentlyContinue
} catch { }

foreach ($m in $Modules) {
    Save-Module -Name $m -Path $ModulePath -Force
}

Write-Host "Modules saved to $ModulePath"
