#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Phase {
  param(
    [Parameter(Mandatory = $true)][string]$Title
  )
  Write-Host ""
  Write-Host "==============================="
  Write-Host "Phase: $Title"
  Write-Host "==============================="
}

function Ensure-RoleAssignment {
  param(
    [Parameter(Mandatory = $true)][string]$PrincipalId,
    [Parameter(Mandatory = $true)][string]$Scope,
    [Parameter(Mandatory = $true)][string]$Role,
    [string]$PrincipalType = "ServicePrincipal"
  )
  $existing = az role assignment list --assignee-object-id $PrincipalId --scope $Scope --query "[?roleDefinitionName=='$Role'] | length(@)" -o tsv
  if ([int]$existing -eq 0) {
    az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type $PrincipalType --role $Role --scope $Scope | Out-Null
  } else {
    Write-Host "Role '$Role' already assigned at scope."
  }
}

function Ensure-StorageContainer {
  param(
    [Parameter(Mandatory = $true)][string]$AccountName,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $exists = az storage container exists --account-name $AccountName --auth-mode login -n $Name --query exists -o tsv
  if ($exists -ne "true") {
    az storage container create --account-name $AccountName --auth-mode login -n $Name | Out-Null
  } else {
    Write-Host "Container '$Name' already exists."
  }
}

function Ensure-StorageQueue {
  param(
    [Parameter(Mandatory = $true)][string]$AccountName,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $exists = az storage queue exists --account-name $AccountName --auth-mode login -n $Name --query exists -o tsv
  if ($exists -ne "true") {
    az storage queue create --account-name $AccountName --auth-mode login -n $Name | Out-Null
  } else {
    Write-Host "Queue '$Name' already exists."
  }
}

function Ensure-CosmosRoleAssignment {
  param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$AccountName,
    [Parameter(Mandatory = $true)][string]$RoleDefinitionId,
    [Parameter(Mandatory = $true)][string]$PrincipalId
  )
  $existing = az cosmosdb sql role assignment list -g $ResourceGroup -a $AccountName --query "[?principalId=='$PrincipalId' && roleDefinitionId=='$RoleDefinitionId'] | length(@)" -o tsv
  if ([int]$existing -eq 0) {
    az cosmosdb sql role assignment create -g $ResourceGroup -a $AccountName --role-definition-id $RoleDefinitionId --principal-id $PrincipalId --scope "/" | Out-Null
  } else {
    Write-Host "Cosmos DB role assignment already exists for principal."
  }
}

if ($args.Count -ne 2) {
    Write-Host "Usage: ./provision.ps1 <name-prefix> <resource-group>"
    exit 1
}

$prefix = $args[0]
$rg = $args[1]
$location = "swedencentral"
$storage = "${prefix}storage"
$queue = "hr-ingest-q"
$attachmentsQueue = "hr-attachments-q"
$functionapp = "${prefix}-func"
$cosmos = "${prefix}-cosmos"
$database = "hrdb"
$container = "emails"
$logicapp = "${prefix}-logic"
$uami = "${prefix}-uami"

Write-Phase "Sign in & subscription context"
Write-Host "Signing into Azure..."
az login --tenant "5380364e-35d4-4293-8bfe-fa76e835384e" | Out-Null
Write-Host "Setting subscription..."
az account set --subscription "b2af20ad-98fa-4aa7-94c3-059663641d9f"

Write-Phase "Resource group & region checks"
Write-Host "Checking resource group..."
$rgExists = az group exists -n $rg | Out-String
if ($rgExists.Trim().ToLower() -ne "true") {
  Write-Host "Creating resource group '$rg' in $location..."
  az group create -n $rg -l $location | Out-Null
}

Write-Host "Checking Flex Consumption region support..."
$flexRegions = az functionapp list-flexconsumption-locations --query "[].name" -o tsv
if (-not ($flexRegions -split "\s+" | Where-Object { $_ -eq $location })) {
  Write-Error "Region '$location' does not support Flex Consumption. Run 'az functionapp list-flexconsumption-locations' to choose a supported region."
  exit 1
}

Write-Phase "Local dependencies"
Write-Host "Preparing local PowerShell modules for Flex (saved under FunctionApp/modules)..."
& pwsh -NoLogo -NoProfile -File ./fetch-modules.ps1

Write-Phase "Identity setup"
Write-Host "Creating user-assigned managed identity..."
$uamiId = az identity show -g $rg -n $uami --query id -o tsv 2>$null
if (-not $uamiId) {
  $uamiId = az identity create -g $rg -n $uami --query id -o tsv
}
$uamiPrincipalId = az identity show -g $rg -n $uami --query principalId -o tsv 2>$null
$uamiClientId = az identity show -g $rg -n $uami --query clientId -o tsv 2>$null

$subscriptionId = az account show --query id -o tsv
$signedInObjectId = az ad signed-in-user show --query id -o tsv

Write-Phase "Storage account"
Write-Host "Creating storage account (shared key access disabled)..."
$storageId = az storage account show -g $rg -n $storage --query id -o tsv 2>$null
if (-not $storageId) {
  az storage account create -g $rg -n $storage -l $location --sku Standard_LRS --allow-shared-key-access false | Out-Null
} else {
  Write-Host "Storage account '$storage' already exists."
}

Write-Host "Ensuring storage public network access is enabled..."
$storagePublicAccess = az storage account show -g $rg -n $storage --query publicNetworkAccess -o tsv 2>$null
if ($storagePublicAccess -ne "Enabled") {
  az storage account update -g $rg -n $storage --public-network-access Enabled | Out-Null
  Write-Host "Storage public network access enabled."
} else {
  Write-Host "Storage public network access already enabled."
}

Write-Host "Assigning storage data roles to signed-in user (for container/queue creation)..."
$storageScope = "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage"
Ensure-RoleAssignment -PrincipalId $signedInObjectId -Scope $storageScope -Role "Storage Blob Data Contributor" -PrincipalType "User"
Ensure-RoleAssignment -PrincipalId $signedInObjectId -Scope $storageScope -Role "Storage Queue Data Contributor" -PrincipalType "User"

Write-Host "Creating blob containers and queues..."
Ensure-StorageContainer -AccountName $storage -Name emails
Ensure-StorageContainer -AccountName $storage -Name deployments
Ensure-StorageQueue -AccountName $storage -Name $queue
Ensure-StorageQueue -AccountName $storage -Name $attachmentsQueue

Write-Host "Assigning storage data roles to UAMI..."
Ensure-RoleAssignment -PrincipalId $uamiPrincipalId -Scope $storageScope -Role "Storage Blob Data Contributor"
Ensure-RoleAssignment -PrincipalId $uamiPrincipalId -Scope $storageScope -Role "Storage Queue Data Contributor"

Write-Phase "Cosmos DB"
Write-Host "Creating Cosmos DB account, database, and container..."
$cosmosId = az cosmosdb show -g $rg -n $cosmos --query id -o tsv 2>$null
if (-not $cosmosId) {
  az cosmosdb create -g $rg -n $cosmos --kind GlobalDocumentDB --capabilities EnableServerless | Out-Null
} else {
  Write-Host "Cosmos DB account '$cosmos' already exists."
}

Write-Host "Ensuring Cosmos DB public network access is enabled..."
$cosmosPublicAccess = az cosmosdb show -g $rg -n $cosmos --query publicNetworkAccess -o tsv 2>$null
if ($cosmosPublicAccess -ne "Enabled") {
  az cosmosdb update -g $rg -n $cosmos --public-network-access Enabled | Out-Null
  Write-Host "Cosmos DB public network access enabled."
} else {
  Write-Host "Cosmos DB public network access already enabled."
}

$dbExists = az cosmosdb sql database show -g $rg -a $cosmos -n $database --query id -o tsv 2>$null
if (-not $dbExists) {
  az cosmosdb sql database create -g $rg -a $cosmos -n $database | Out-Null
} else {
  Write-Host "Cosmos DB database '$database' already exists."
}

$containerExists = az cosmosdb sql container show -g $rg -a $cosmos -d $database -n $container --query id -o tsv 2>$null
if (-not $containerExists) {
  az cosmosdb sql container create -g $rg -a $cosmos -d $database -n $container --partition-key-path "/pk" | Out-Null
} else {
  Write-Host "Cosmos DB container '$container' already exists."
}
$cosmosEndpoint = az cosmosdb show -g $rg -n $cosmos --query documentEndpoint -o tsv 2>$null

Write-Host "Assigning Cosmos DB data role to UAMI..."
$cosmosRoleDefId = az cosmosdb sql role definition list -g $rg -a $cosmos --query "[?roleName=='Cosmos DB Built-in Data Contributor'].id" -o tsv 2>$null
Ensure-CosmosRoleAssignment -ResourceGroup $rg -AccountName $cosmos -RoleDefinitionId $cosmosRoleDefId -PrincipalId $uamiPrincipalId
Write-Host "Assigning Cosmos DB data role to signed-in user..."
Ensure-CosmosRoleAssignment -ResourceGroup $rg -AccountName $cosmos -RoleDefinitionId $cosmosRoleDefId -PrincipalId $signedInObjectId

Write-Phase "Function App (Flex Consumption)"
Write-Host "Creating Function App..."
$functionExists = az functionapp show -g $rg -n $functionapp --query id -o tsv 2>$null
if (-not $functionExists) {
  az functionapp create -g $rg -n $functionapp --storage-account $storage --flexconsumption-location $location --runtime powershell --runtime-version 7.4 --assign-identity $uamiId `
    --deployment-storage-name $storage `
    --deployment-storage-container-name deployments `
    --deployment-storage-auth-type UserAssignedIdentity `
    --deployment-storage-auth-value $uamiId | Out-Null
} else {
  Write-Host "Function App '$functionapp' already exists. Ensuring identity assignment..."
  az functionapp identity assign -g $rg -n $functionapp --identities $uamiId | Out-Null
}
  
Write-Host "Configuring app settings (managed identity auth for Storage and Cosmos DB)..."
az functionapp config appsettings set -g $rg -n $functionapp --settings `
  "AzureWebJobsStorage__accountName=$storage" `
  "AzureWebJobsStorage__credential=managedidentity" `
  "AzureWebJobsStorage__clientId=$uamiClientId" `
  "CosmosDBConnection__accountEndpoint=$cosmosEndpoint" `
  "CosmosDBConnection__credential=managedidentity" `
  "CosmosDBConnection__clientId=$uamiClientId"

Write-Host "Removing any key-based Storage settings (if present)..."
az functionapp config appsettings delete -g $rg -n $functionapp --setting-names AzureWebJobsStorage AzureWebJobsStorage__connectionString WEBSITE_CONTENTAZUREFILECONNECTIONSTRING WEBSITE_CONTENTSHARE | Out-Null

Write-Host "Creating Application Insights..."
$aiName = "${functionapp}-ai"
$aiExists = az monitor app-insights component show -g $rg -a $aiName --query id -o tsv 2>$null
if (-not $aiExists) {
  az monitor app-insights component create -g $rg -a $aiName -l $location | Out-Null
} else {
  Write-Host "Application Insights '$aiName' already exists."
}
$aiConnectionString = az monitor app-insights component show -g $rg -a $aiName --query connectionString -o tsv 2>$null
az functionapp config appsettings set -g $rg -n $functionapp --settings "APPLICATIONINSIGHTS_CONNECTION_STRING=$aiConnectionString"

Write-Host "Ensuring CORS allows Azure Portal..."
az functionapp cors add -g $rg -n $functionapp --allowed-origins "https://portal.azure.com" | Out-Null

Write-Phase "Event Grid"
Write-Host "Creating Event Grid subscription with filters..."
$egSubName = "${prefix}-egsub"
$egExists = az eventgrid event-subscription show --name $egSubName --source-resource-id "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage" --query id -o tsv 2>$null
if (-not $egExists) {
  $queueResourceId = "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage/queueServices/default/queues/$attachmentsQueue"
  az eventgrid event-subscription create `
    --name $egSubName `
    --source-resource-id "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage" `
    --endpoint-type storagequeue `
    --endpoint $queueResourceId `
    --included-event-types Microsoft.Storage.BlobCreated `
    --subject-begins-with "/blobServices/default/containers/emails/blobs/emails/" `
    --subject-ends-with "/attachments/" | Out-Null
} else {
  Write-Host "Event Grid subscription '$egSubName' already exists."
}

Write-Phase "Next steps"
Write-Host "Logic App placeholder (manual build in portal): $logicapp"
Write-Host "Deploy function code with: func azure functionapp publish $functionapp"

Write-Host "Done. All resources are provisioned."
