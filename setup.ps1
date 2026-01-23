#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploy or delete infrastructure using Azure Deployment Stacks.

.DESCRIPTION
    Uses Azure PowerShell to manage infrastructure as a deployment stack.
    Supports create/update and delete operations.

.PARAMETER Prefix
    Name prefix for all resources (3-11 chars, lowercase).

.PARAMETER ResourceGroup
    Target resource group name.

.PARAMETER Location
    Azure region (default: swedencentral).

.PARAMETER Delete
    If specified, deletes the stack and all resources.

.EXAMPLE
    ./setup.ps1 -Prefix "anb888" -ResourceGroup "anbo-ints-usecase-3"

.EXAMPLE
    ./setup.ps1 -Prefix "anb888" -ResourceGroup "anbo-ints-usecase-3" -Delete
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(3, 11)]
    [string]$Prefix,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$Location = "swedencentral",

    [Parameter(Mandatory = $false)]
    [switch]$Delete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Stack and template configuration
$stackName = "$Prefix-stack"
$bicepFile = Join-Path $PSScriptRoot "infra/main.bicep"
$armTemplateFile = Join-Path $PSScriptRoot "infra/main.json"

function Write-Phase {
    param([string]$Title)
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "Phase: $Title" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
}

# Ensure required modules are installed and up-to-date
Write-Phase "Prerequisites"
$requiredModules = @("Az.Accounts", "Az.Resources", "Bicep")

foreach ($moduleName in $requiredModules) {
    $installed = Get-Module -Name $moduleName -ListAvailable | 
        Sort-Object Version -Descending | 
        Select-Object -First 1
    
    # Check if update is available
    $online = Find-Module -Name $moduleName -ErrorAction SilentlyContinue
    
    if (-not $installed) {
        Write-Host "Installing $moduleName..."
        Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber
    } elseif ($online -and $online.Version -gt $installed.Version) {
        Write-Host "Updating $moduleName from v$($installed.Version) to v$($online.Version)..."
        Update-Module -Name $moduleName -Force -ErrorAction SilentlyContinue
        # Fallback if Update-Module fails (e.g., module installed via different method)
        if ($?) {
            Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber -ErrorAction SilentlyContinue
        }
    }
    
    Import-Module -Name $moduleName -Force
    $loadedModule = Get-Module -Name $moduleName
    Write-Host "$moduleName v$($loadedModule.Version) - OK"
}

# Compile Bicep to ARM JSON using PSBicep module
Write-Host ""
Write-Host "Compiling Bicep template..."
try {
    Build-Bicep -Path $bicepFile -OutputPath $armTemplateFile -ErrorAction Stop
    Write-Host "Bicep compiled successfully: $armTemplateFile"
} catch {
    if (Test-Path $armTemplateFile) {
        Write-Host "Bicep compilation failed, using pre-compiled ARM template" -ForegroundColor Yellow
        Write-Host "Error: $_" -ForegroundColor Yellow
    } else {
        Write-Error "Bicep compilation failed and no pre-compiled template exists: $_"
        exit 1
    }
}

# Ensure logged in
Write-Phase "Authentication"
$tenantId = "5380364e-35d4-4293-8bfe-fa76e835384e"

function Test-AzureConnection {
    param([string]$TenantId)
    try {
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context -or $context.Tenant.Id -ne $TenantId) {
            return $false
        }
        # Actually test the token by making an API call
        $null = Get-AzResourceGroup -ErrorAction Stop | Select-Object -First 1
        return $true
    } catch {
        return $false
    }
}

if (Test-AzureConnection -TenantId $tenantId) {
    $context = Get-AzContext
    Write-Host "Logged in as: $($context.Account.Id)"
    Write-Host "Subscription: $($context.Subscription.Name)"
} else {
    Write-Host "Authentication required or token expired..."
    Write-Host "Clearing stale context and reconnecting..."
    
    # Clear any stale context
    Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
    Clear-AzContext -Force -ErrorAction SilentlyContinue | Out-Null
    
    # Fresh login
    Write-Host "Connecting to Azure (tenant: $tenantId)..."
    Connect-AzAccount -Tenant $tenantId -ErrorAction Stop
    
    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Failed to authenticate. Please run 'Connect-AzAccount -Tenant $tenantId' manually."
        exit 1
    }
    Write-Host "Logged in as: $($context.Account.Id)"
    Write-Host "Subscription: $($context.Subscription.Name)"
}

# Ensure resource group exists
Write-Phase "Resource Group"
$rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "Creating resource group '$ResourceGroup' in $Location..."
    New-AzResourceGroup -Name $ResourceGroup -Location $Location | Out-Null
} else {
    Write-Host "Resource group '$ResourceGroup' exists."
}

if ($Delete) {
    # Delete the stack and all resources
    Write-Phase "Delete Stack"
    
    $existingStack = Get-AzResourceGroupDeploymentStack -Name $stackName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
    if ($existingStack) {
        Write-Host "Deleting stack '$stackName' and all managed resources..."
        Remove-AzResourceGroupDeploymentStack `
            -Name $stackName `
            -ResourceGroupName $ResourceGroup `
            -ActionOnUnmanage DeleteAll `
            -Force
        Write-Host "Stack and all resources deleted." -ForegroundColor Green
    } else {
        Write-Host "Stack '$stackName' does not exist." -ForegroundColor Yellow
    }
} else {
    # Download PowerShell modules for Flex Consumption
    Write-Phase "Local Dependencies"
    Write-Host "Preparing local PowerShell modules for Flex Consumption..."
    $fetchModulesScript = Join-Path $PSScriptRoot "fetch-modules.ps1"
    if (Test-Path $fetchModulesScript) {
        & $fetchModulesScript
    } else {
        Write-Host "Warning: fetch-modules.ps1 not found, skipping module download." -ForegroundColor Yellow
    }
    
    # Create or update the stack
    Write-Phase "Deploy Stack"
    
    Write-Host "Deploying stack '$stackName'..."
    Write-Host "  Template: $armTemplateFile"
    Write-Host "  Prefix: $Prefix"
    Write-Host "  Location: $Location"
    
    $result = Set-AzResourceGroupDeploymentStack `
        -Name $stackName `
        -ResourceGroupName $ResourceGroup `
        -TemplateFile $armTemplateFile `
        -TemplateParameterObject @{ prefix = $Prefix; location = $Location } `
        -ActionOnUnmanage DeleteAll `
        -DenySettingsMode None `
        -Force

    Write-Phase "Deployment Complete"
    Write-Host "Stack: $stackName" -ForegroundColor Green
    Write-Host "Status: $($result.ProvisioningState)" -ForegroundColor Green
    
    # Show outputs
    if ($result.Outputs) {
        Write-Host ""
        Write-Host "Outputs:" -ForegroundColor Cyan
        $result.Outputs.GetEnumerator() | ForEach-Object {
            Write-Host "  $($_.Key): $($_.Value.Value)"
        }
    }
    
    Write-Host ""
    Write-Host "To delete all resources, run:" -ForegroundColor Yellow
    Write-Host "  ./setup.ps1 -Prefix '$Prefix' -ResourceGroup '$ResourceGroup' -Delete" -ForegroundColor Yellow
}
