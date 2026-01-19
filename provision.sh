#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <name-prefix> <resource-group>"
  exit 1
fi

prefix=$1
rg=$2
location="swedencentral"
storage="${prefix}storage"
queue="hr-ingest-q"
attachmentsQueue="hr-attachments-q"
functionapp="${prefix}-func"
plan="${prefix}-plan"
cosmos="${prefix}-cosmos"
database="hrdb"
container="emails"
logicapp="${prefix}-logic"
uami="${prefix}-uami"

echo "Preparing local PowerShell modules for Flex (saved under FunctionApp/modules)..."
pwsh -NoLogo -NoProfile -File ./fetch-modules.ps1

echo "Managed identity..."
uamiId=$(az identity create -g "$rg" -n "$uami" --query id -o tsv)

echo "Storage account..."
az storage account create -g "$rg" -n "$storage" -l "$location" --sku Standard_LRS
accountKey=$(az storage account keys list -g "$rg" -n "$storage" --query "[0].value" -o tsv)
az storage container create --account-name "$storage" --account-key "$accountKey" -n emails
az storage queue create --account-name "$storage" --account-key "$accountKey" -n "$queue"
az storage queue create --account-name "$storage" --account-key "$accountKey" -n "$attachmentsQueue"

echo "Cosmos DB..."
az cosmosdb create -g "$rg" -n "$cosmos" --kind GlobalDocumentDB --capabilities EnableServerless
az cosmosdb sql database create -g "$rg" -a "$cosmos" -n "$database"
az cosmosdb sql container create -g "$rg" -a "$cosmos" -d "$database" -n "$container" --partition-key-path "/pk"
cosmosConn=$(az cosmosdb keys list -g "$rg" -n "$cosmos" --type connection-strings --query "connectionStrings[0].connectionString" -o tsv)

echo "Function App on Flex Consumption..."
az functionapp plan create -g "$rg" -n "$plan" --location "$location" --sku FC1 --is-linux
az functionapp create -g "$rg" -p "$plan" -n "$functionapp" --storage-account "$storage" --runtime powershell --runtime-version 7.4 --functions-version 4 --os-type Linux --assign-identity "$uamiId"
az functionapp config appsettings set -g "$rg" -n "$functionapp" --settings AzureWebJobsStorage="DefaultEndpointsProtocol=https;AccountName=$storage;AccountKey=$accountKey;EndpointSuffix=core.windows.net" CosmosDBConnection="$cosmosConn"
az monitor app-insights component create -g "$rg" -a "${functionapp}-ai" -l "$location"
aiConnectionString=$(az monitor app-insights component show -g "$rg" -a "${functionapp}-ai" --query connectionString -o tsv)
az functionapp config appsettings set -g "$rg" -n "$functionapp" --settings "APPLICATIONINSIGHTS_CONNECTION_STRING=$aiConnectionString"

echo "Event Grid subscription with filters..."
az eventgrid event-subscription create \
  --name "${prefix}-egsub" \
  --source-resource-id "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage" \
  --endpoint-type storagequeue \
  --queue-resource-id "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage/queueServices/default/queues/$attachmentsQueue" \
  --included-event-types Microsoft.Storage.BlobCreated \
  --subject-begins-with "/blobServices/default/containers/emails/blobs/emails/" \
  --subject-ends-with "/attachments/"

echo "Logic App placeholder (manual build in portal): $logicapp"
echo "Deploy function code with 'func azure functionapp publish $functionapp' after installing Azure Functions Core Tools."

echo "Done."
