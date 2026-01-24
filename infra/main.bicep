// ============================================================
// main.bicep - Wrapper template (shared + app)
// ============================================================

targetScope = 'resourceGroup'

@description('Name prefix for all resources (lowercase)')
@minLength(3)
@maxLength(11)
param prefix string

@description('Azure region for deployment')
param location string = 'swedencentral'

@description('Create shared resource-group resources (partner configuration)')
param deploySharedResources bool = false

@description('Create Event Grid Partner Topic subscription to Storage Queue (requires Graph subscription to exist)')
param createGraphPartnerTopicEventSubscription bool = false

@description('Microsoft Graph Partner Topic name (shared across apps)')
param graphPartnerTopicName string = 'graph-users-topic'

@description('Optional override for the Partner Topic event subscription name')
param graphPartnerEventSubscriptionName string = ''

module shared 'rg-shared.bicep' = if (deploySharedResources) {
  name: 'shared-resources'
}

module app 'app.bicep' = {
  name: 'app-resources'
  params: {
    prefix: prefix
    location: location
    createGraphPartnerTopicEventSubscription: createGraphPartnerTopicEventSubscription
    graphPartnerTopicName: graphPartnerTopicName
    graphPartnerEventSubscriptionName: graphPartnerEventSubscriptionName
  }
}

output functionAppName string = app.outputs.functionAppName
output functionAppHostName string = app.outputs.functionAppHostName
output storageAccountName string = app.outputs.storageAccountName
output cosmosAccountName string = app.outputs.cosmosAccountName
output cosmosEndpoint string = app.outputs.cosmosEndpoint
output appInsightsConnectionString string = app.outputs.appInsightsConnectionString
output managedIdentityClientId string = app.outputs.managedIdentityClientId
output managedIdentityPrincipalId string = app.outputs.managedIdentityPrincipalId
output managedIdentityResourceId string = app.outputs.managedIdentityResourceId
output graphPartnerTopicName string = app.outputs.graphPartnerTopicName
output graphPartnerEventSubscriptionName string = app.outputs.graphPartnerEventSubscriptionName
