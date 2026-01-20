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
$uamiId = az identity create -g $rg -n $uami --query id -o tsv
$uamiPrincipalId = az identity show -g $rg -n $uami --query principalId -o tsv
$uamiClientId = az identity show -g $rg -n $uami --query clientId -o tsv

$subscriptionId = az account show --query id -o tsv
$signedInObjectId = az ad signed-in-user show --query id -o tsv

Write-Phase "Storage account"
Write-Host "Creating storage account (shared key access disabled)..."
az storage account create -g $rg -n $storage -l $location --sku Standard_LRS --allow-shared-key-access false

Write-Host "Assigning storage data roles to signed-in user (for container/queue creation)..."
$storageScope = "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage"
az role assignment create --assignee-object-id $signedInObjectId --assignee-principal-type User --role "Storage Blob Data Contributor" --scope $storageScope
az role assignment create --assignee-object-id $signedInObjectId --assignee-principal-type User --role "Storage Queue Data Contributor" --scope $storageScope

Write-Host "Creating blob containers and queues..."
az storage container create --account-name $storage --auth-mode login -n emails
az storage container create --account-name $storage --auth-mode login -n deployments
az storage queue create --account-name $storage --auth-mode login -n $queue
az storage queue create --account-name $storage --auth-mode login -n $attachmentsQueue

Write-Host "Assigning storage data roles to UAMI..."
az role assignment create --assignee-object-id $uamiPrincipalId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope $storageScope
az role assignment create --assignee-object-id $uamiPrincipalId --assignee-principal-type ServicePrincipal --role "Storage Queue Data Contributor" --scope $storageScope

Write-Phase "Cosmos DB"
Write-Host "Creating Cosmos DB account, database, and container..."
az cosmosdb create -g $rg -n $cosmos --kind GlobalDocumentDB --capabilities EnableServerless
az cosmosdb sql database create -g $rg -a $cosmos -n $database
az cosmosdb sql container create -g $rg -a $cosmos -d $database -n $container --partition-key-path "/pk"
$cosmosEndpoint = az cosmosdb show -g $rg -n $cosmos --query documentEndpoint -o tsv

Write-Host "Assigning Cosmos DB data role to UAMI..."
$cosmosRoleDefId = az cosmosdb sql role definition list -g $rg -a $cosmos --query "[?roleName=='Cosmos DB Built-in Data Contributor'].id" -o tsv
az cosmosdb sql role assignment create -g $rg -a $cosmos --role-definition-id $cosmosRoleDefId --principal-id $uamiPrincipalId --scope "/"
Write-Host "Assigning Cosmos DB data role to signed-in user..."
az cosmosdb sql role assignment create -g $rg -a $cosmos --role-definition-id $cosmosRoleDefId --principal-id $signedInObjectId --scope "/"

Write-Phase "Function App (Flex Consumption)"
Write-Host "Creating Function App..."
az functionapp create -g $rg -n $functionapp --storage-account $storage --flexconsumption-location $location --runtime powershell --runtime-version 7.4 --assign-identity $uamiId `
  --deployment-storage-name $storage `
  --deployment-storage-container-name deployments `
  --deployment-storage-auth-type UserAssignedIdentity `
  --deployment-storage-auth-value $uamiId
  
Write-Host "Configuring app settings (managed identity auth for Storage and Cosmos DB)..."
az functionapp config appsettings set -g $rg -n $functionapp --settings `
  "AzureWebJobsStorage__accountName=$storage" `
  "AzureWebJobsStorage__credential=managedidentity" `
  "AzureWebJobsStorage__clientId=$uamiClientId" `
  "CosmosDBConnection__accountEndpoint=$cosmosEndpoint" `
  "CosmosDBConnection__credential=managedidentity" `
  "CosmosDBConnection__clientId=$uamiClientId"

Write-Host "Creating Application Insights..."
az monitor app-insights component create -g $rg -a "${functionapp}-ai" -l $location
$aiConnectionString = az monitor app-insights component show -g $rg -a "${functionapp}-ai" --query connectionString -o tsv
az functionapp config appsettings set -g $rg -n $functionapp --settings "APPLICATIONINSIGHTS_CONNECTION_STRING=$aiConnectionString"

Write-Phase "Event Grid"
Write-Host "Creating Event Grid subscription with filters..."
az eventgrid event-subscription create `
  --name "${prefix}-egsub" `
  --source-resource-id "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage" `
  --endpoint-type storagequeue `
  --queue-resource-id "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage/queueServices/default/queues/$attachmentsQueue" `
  --included-event-types Microsoft.Storage.BlobCreated `
  --subject-begins-with "/blobServices/default/containers/emails/blobs/emails/" `
  --subject-ends-with "/attachments/"

Write-Phase "Next steps"
Write-Host "Logic App placeholder (manual build in portal): $logicapp"
Write-Host "Deploy function code with: func azure functionapp publish $functionapp"

Write-Host "Done. All resources are provisioned."
