// ============================================================
// main.bicep - Full infrastructure for fun-with-function
// Migrated from provision.ps1
// ============================================================

targetScope = 'resourceGroup'

@description('Name prefix for all resources (lowercase)')
@minLength(3)
@maxLength(11)
param prefix string

@description('Azure region for deployment')
param location string = 'swedencentral'

@description('Client ID of the App Registration federated to UAMI for Graph API access')
param graphAppClientId string = 'bebcf6cd-b423-454d-a4a6-3cfd9d107886'

@description('Create Event Grid Partner Topic subscription to Storage Queue (requires Graph subscription to exist)')
param createGraphPartnerTopicEventSubscription bool = false

@description('Microsoft Graph Partner Topic name (shared across apps)')
param graphPartnerTopicName string = 'graph-users-topic'

@description('Optional override for the Partner Topic event subscription name')
param graphPartnerEventSubscriptionName string = ''

@description('Optional objectId for current user to grant Event Grid permissions')
param currentUserObjectId string = ''

// ============================================================
// Variables - Resource Names
// ============================================================
var storageName = '${prefix}storage'
var functionAppName = '${prefix}-func'
var appServicePlanName = '${prefix}-asp'
var cosmosName = '${prefix}-cosmos'
var uamiName = '${prefix}-uami'
var logAnalyticsName = '${prefix}-law'
var appInsightsName = '${prefix}-func-ai'
var eventGridTopicName = '${prefix}-storage-topic'
var eventGridSubName = '${prefix}-egsub-attachments'
var eventGridMetadataSubName = '${prefix}-egsub-metadata'

// ============================================================
// Variables - Resource Sub-Names
// ============================================================
var cosmosDatabaseName = 'graphdb'
var cosmosContainerName = 'graphSnapshots'
var emailsContainerName = 'graphSnapshots'
var deploymentsContainerName = 'deployments'
var attachmentsQueueName = 'graph-attachments-q'
var metadataQueueName = 'graph-metadata-q'
var userChangesQueueName = 'graph-user-changes-q'
var partitionKeyPath = '/pk'

var graphPartnerEventSubName = graphPartnerEventSubscriptionName == '' ? '${prefix}-graph-users-queue-sub' : graphPartnerEventSubscriptionName

// ============================================================
// Variables - Built-in Role Definition IDs
// ============================================================
var storageBlobDataOwnerRole = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRole = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageQueueDataMessageSenderRole = 'c6a89b2d-59bc-44d0-9896-0f6e12d7b80a' // Required for Event Grid to write to queue via UAMI
var eventGridContributorRole = '1e241071-0855-49ea-94dc-649edcd759de'
var eventGridEventSubscriptionContributorRole = '428e0ff0-5e57-4d9c-a221-2c70d0e0a443' // Required for UAMI to create Event Subscriptions

// ============================================================
// User-Assigned Managed Identity
// ============================================================
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: uamiName
  location: location
}

// ============================================================
// Storage Account (shared key access disabled)
// ============================================================
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
  }
}

// Blob Services
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

// Blob Containers
resource emailsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: emailsContainerName
}

resource deploymentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentsContainerName
}

// Queue Services
resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

// Storage Queues
resource attachmentsQueueResource 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: attachmentsQueueName
}

resource metadataQueueResource 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: metadataQueueName
}

resource userChangesQueueResource 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: userChangesQueueName
}

// ============================================================
// Storage Role Assignments for Managed Identity
// ============================================================
resource storageBlobDataOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, managedIdentity.id, storageBlobDataOwnerRole)
  scope: storageAccount
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRole)
  }
}

resource storageQueueDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, managedIdentity.id, storageQueueDataContributorRole)
  scope: storageAccount
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRole)
  }
}

resource eventGridContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, managedIdentity.id, eventGridContributorRole)
  scope: storageAccount
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventGridContributorRole)
  }
}

// UAMI needs Event Grid Contributor at RG scope to activate Partner Topics
resource eventGridContributorRgAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, eventGridContributorRole)
  scope: resourceGroup()
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventGridContributorRole)
  }
}

// UAMI needs Storage Queue Data Message Sender for Event Grid to deliver via managed identity
resource storageQueueDataMessageSenderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, managedIdentity.id, storageQueueDataMessageSenderRole)
  scope: storageAccount
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataMessageSenderRole)
  }
}

// Optional: grant Storage permissions to current user
resource currentUserStorageBlobDataOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (currentUserObjectId != '') {
  name: guid(storageAccount.id, currentUserObjectId, storageBlobDataOwnerRole)
  scope: storageAccount
  properties: {
    principalId: currentUserObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRole)
  }
}

resource currentUserStorageQueueDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (currentUserObjectId != '') {
  name: guid(storageAccount.id, currentUserObjectId, storageQueueDataContributorRole)
  scope: storageAccount
  properties: {
    principalId: currentUserObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRole)
  }
}

resource currentUserStorageQueueDataMessageSenderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (currentUserObjectId != '') {
  name: guid(storageAccount.id, currentUserObjectId, storageQueueDataMessageSenderRole)
  scope: storageAccount
  properties: {
    principalId: currentUserObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataMessageSenderRole)
  }
}

// UAMI needs EventGrid EventSubscription Contributor to create Event Subscriptions on Partner Topics
resource eventGridEventSubContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, eventGridEventSubscriptionContributorRole)
  scope: resourceGroup()
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventGridEventSubscriptionContributorRole)
  }
}

// Optional: grant Event Grid permissions to current user for activation/management
resource currentUserEventGridContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (currentUserObjectId != '') {
  name: guid(resourceGroup().id, currentUserObjectId, eventGridContributorRole)
  scope: resourceGroup()
  properties: {
    principalId: currentUserObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventGridContributorRole)
  }
}

resource currentUserEventGridEventSubContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (currentUserObjectId != '') {
  name: guid(resourceGroup().id, currentUserObjectId, eventGridEventSubscriptionContributorRole)
  scope: resourceGroup()
  properties: {
    principalId: currentUserObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventGridEventSubscriptionContributorRole)
  }
}

// ============================================================
// Cosmos DB Account (Serverless)
// ============================================================
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: cosmosName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    publicNetworkAccess: 'Enabled'
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
  }
}

// Cosmos DB SQL Database
resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmosAccount
  name: cosmosDatabaseName
  properties: {
    resource: {
      id: cosmosDatabaseName
    }
  }
}

// Cosmos DB SQL Container
resource cosmosContainerResource 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: cosmosDatabase
  name: cosmosContainerName
  properties: {
    resource: {
      id: cosmosContainerName
      partitionKey: {
        paths: [partitionKeyPath]
        kind: 'Hash'
      }
    }
  }
}

// Cosmos DB SQL Role Assignment for Managed Identity
// Using built-in "Cosmos DB Built-in Data Contributor" role
resource cosmosRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, managedIdentity.id, 'data-contributor')
  properties: {
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: cosmosAccount.id
  }
}

// Optional: grant Cosmos DB data access to current user
resource currentUserCosmosRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = if (currentUserObjectId != '') {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, currentUserObjectId, 'data-contributor')
  properties: {
    principalId: currentUserObjectId
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: cosmosAccount.id
  }
}

// ============================================================
// Log Analytics Workspace (required for App Insights)
// ============================================================
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ============================================================
// Application Insights
// ============================================================
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ============================================================
// App Service Plan (Flex Consumption)
// ============================================================
resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

// ============================================================
// Function App (Flex Consumption)
// ============================================================
resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
        ]
      }
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storageAccount.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: managedIdentity.properties.clientId }
        { name: 'CosmosDBConnection__accountEndpoint', value: cosmosAccount.properties.documentEndpoint }
        { name: 'CosmosDBConnection__credential', value: 'managedidentity' }
        { name: 'CosmosDBConnection__clientId', value: managedIdentity.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'GRAPH_APP_CLIENT_ID', value: graphAppClientId }
        { name: 'AZURE_TENANT_ID', value: tenant().tenantId }
        { name: 'AZURE_SUBSCRIPTION_ID', value: subscription().subscriptionId }
        { name: 'RESOURCE_GROUP', value: resourceGroup().name }
        { name: 'LOCATION', value: location }
        { name: 'PREFIX', value: prefix }
        { name: 'GRAPH_PARTNER_TOPIC_NAME', value: graphPartnerTopicName }
        { name: 'GRAPH_PARTNER_EVENT_SUB_NAME', value: graphPartnerEventSubName }
        { name: 'GRAPH_USER_CHANGES_QUEUE_NAME', value: userChangesQueueName }
        { name: 'MANAGED_IDENTITY_RESOURCE_ID', value: managedIdentity.id }
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}${deploymentsContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: managedIdentity.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'powershell'
        version: '7.4'
      }
    }
  }
}

// ============================================================
// Event Grid System Topic for Storage (with UAMI for delivery)
// ============================================================
resource eventGridSystemTopic 'Microsoft.EventGrid/systemTopics@2025-02-15' = {
  name: eventGridTopicName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    source: storageAccount.id
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

// Event Grid Subscription: Attachments (Blob Created → Storage Queue via UAMI)
resource eventGridSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2025-02-15' = {
  parent: eventGridSystemTopic
  name: eventGridSubName
  properties: {
    deliveryWithResourceIdentity: {
      identity: {
        type: 'UserAssigned'
        userAssignedIdentity: managedIdentity.id
      }
      destination: {
        endpointType: 'StorageQueue'
        properties: {
          resourceId: storageAccount.id
          queueName: attachmentsQueueName
          queueMessageTimeToLiveInSeconds: 604800 // 7 days
        }
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]
      subjectBeginsWith: '/blobServices/default/containers/${emailsContainerName}/blobs/attachments/'
      advancedFilters: [
        {
          operatorType: 'StringIn'
          key: 'data.api'
          values: ['PutBlockList']
        }
      ]
    }
    eventDeliverySchema: 'CloudEventSchemaV1_0'
  }
}

// Event Grid Subscription: Metadata (Blob Created → Storage Queue via UAMI)
resource eventGridMetadataSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2025-02-15' = {
  parent: eventGridSystemTopic
  name: eventGridMetadataSubName
  properties: {
    deliveryWithResourceIdentity: {
      identity: {
        type: 'UserAssigned'
        userAssignedIdentity: managedIdentity.id
      }
      destination: {
        endpointType: 'StorageQueue'
        properties: {
          resourceId: storageAccount.id
          queueName: metadataQueueName
          queueMessageTimeToLiveInSeconds: 604800 // 7 days
        }
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]
      subjectBeginsWith: '/blobServices/default/containers/${emailsContainerName}/blobs/metadata/'
      subjectEndsWith: '/metadata.json'
    }
    eventDeliverySchema: 'CloudEventSchemaV1_0'
  }
}

// ============================================================
// Event Grid Partner Topic Event Subscription (Graph -> Storage Queue)
// Partner Topic is created by Graph when the subscription is created
// ============================================================
resource graphPartnerTopic 'Microsoft.EventGrid/partnerTopics@2024-06-01-preview' existing = if (createGraphPartnerTopicEventSubscription) {
  name: graphPartnerTopicName
}

resource graphPartnerTopicEventSubscription 'Microsoft.EventGrid/partnerTopics/eventSubscriptions@2024-06-01-preview' = if (createGraphPartnerTopicEventSubscription) {
  parent: graphPartnerTopic
  name: graphPartnerEventSubName
  properties: {
    deliveryWithResourceIdentity: {
      identity: {
        type: 'UserAssigned'
        userAssignedIdentity: managedIdentity.id
      }
      destination: {
        endpointType: 'StorageQueue'
        properties: {
          resourceId: storageAccount.id
          queueName: userChangesQueueName
          queueMessageTimeToLiveInSeconds: 604800
        }
      }
    }
    eventDeliverySchema: 'CloudEventSchemaV1_0'
  }
}

// ============================================================
// Outputs
// ============================================================
output functionAppName string = functionApp.name
output functionAppHostName string = functionApp.properties.defaultHostName
output storageAccountName string = storageAccount.name
output cosmosAccountName string = cosmosAccount.name
output cosmosEndpoint string = cosmosAccount.properties.documentEndpoint
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output managedIdentityClientId string = managedIdentity.properties.clientId
output managedIdentityPrincipalId string = managedIdentity.properties.principalId
output managedIdentityResourceId string = managedIdentity.id
output graphPartnerTopicName string = graphPartnerTopicName
output graphPartnerEventSubscriptionName string = graphPartnerEventSubName

// Ready-to-execute az cli command for federated credential (replace <APP_ID>)
output azFederatedCredentialCommand string = 'az ad app federated-credential create --id <APP_ID> --parameters \'{"name":"${uamiName}-federation","issuer":"https://login.microsoftonline.com/${tenant().tenantId}/v2.0","subject":"${managedIdentity.properties.principalId}","audiences":["api://AzureADTokenExchange"],"description":"Federation with UAMI ${uamiName}"}\''
