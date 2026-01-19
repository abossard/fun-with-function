#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <name-prefix>"
  exit 1
fi

prefix=$1
location="westeurope"
rg="${prefix}-rg"
storage="${prefix}storage"
queue="hr-ingest-q"
functionapp="${prefix}-func"
plan="${prefix}-plan"
cosmos="${prefix}-cosmos"
database="hrdb"
container="emails"
logicapp="${prefix}-logic"

echo "Creating resource group..."
az group create -n "$rg" -l "$location"

echo "Storage account..."
az storage account create -g "$rg" -n "$storage" -l "$location" --sku Standard_LRS
accountKey=$(az storage account keys list -g "$rg" -n "$storage" --query "[0].value" -o tsv)
az storage container create --account-name "$storage" --account-key "$accountKey" -n emails
az storage queue create --account-name "$storage" --account-key "$accountKey" -n "$queue"

echo "Cosmos DB..."
az cosmosdb create -g "$rg" -n "$cosmos" --kind GlobalDocumentDB --capabilities EnableServerless
az cosmosdb sql database create -g "$rg" -a "$cosmos" -n "$database"
az cosmosdb sql container create -g "$rg" -a "$cosmos" -d "$database" -n "$container" --partition-key-path "/pk"
cosmosConn=$(az cosmosdb keys list -g "$rg" -n "$cosmos" --type connection-strings --query "connectionStrings[0].connectionString" -o tsv)

echo "Function App on Flex Consumption..."
az functionapp plan create -g "$rg" -n "$plan" --location "$location" --flex-consumption
az functionapp create -g "$rg" -p "$plan" -n "$functionapp" --storage-account "$storage" --runtime powershell --runtime-version 7.4 --functions-version 4 --os-type Linux --consumption-plan-location "$location"
az functionapp config appsettings set -g "$rg" -n "$functionapp" --settings AzureWebJobsStorage="DefaultEndpointsProtocol=https;AccountName=$storage;AccountKey=$accountKey;EndpointSuffix=core.windows.net" CosmosDBConnection="$cosmosConn"
az monitor app-insights component create -g "$rg" -a "${functionapp}-ai" -l "$location"
az functionapp update -g "$rg" -n "$functionapp" --set appInsightsKey=$(az monitor app-insights component show -g "$rg" -a "${functionapp}-ai" --query instrumentationKey -o tsv)

echo "Event Grid subscription with filters..."
az eventgrid event-subscription create \
  --name "${prefix}-egsub" \
  --source-resource-id "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage" \
  --endpoint-type storagequeue \
  --queue-resource-id "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage/queueServices/default/queues/$queue" \
  --included-event-types Microsoft.Storage.BlobCreated \
  --subject-begins-with "/blobServices/default/containers/emails/blobs/emails/" \
  --subject-ends-with "/metadata.json"

echo "Logic App placeholder (manual build in portal): $logicapp"
echo "Deploy function code with 'func azure functionapp publish $functionapp' after installing Azure Functions Core Tools."

echo "Done."
