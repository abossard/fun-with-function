// ============================================================
// rg-shared.bicep - Resource group shared resources
// ============================================================

targetScope = 'resourceGroup'

@description('Create Event Grid Partner Configuration for Microsoft Graph (set true on first deployment per RG)')
param createGraphPartnerConfiguration bool = true

@description('Current UTC time - used for partner authorization expiration calculation')
param nowUtc string = utcNow()

// ============================================================
// Event Grid Partner Configuration (for Microsoft Graph)
// Only created once per resource group, shared by all function apps
// ============================================================

// Microsoft Graph API partner registration ID (well-known)
var graphPartnerRegistrationId = 'c02e0126-707c-436d-b6a1-175d2748fb58'

resource partnerConfiguration 'Microsoft.EventGrid/partnerConfigurations@2024-06-01-preview' = if (createGraphPartnerConfiguration) {
  name: 'default'
  location: 'global'
  properties: {
    partnerAuthorization: {
      defaultMaximumExpirationTimeInDays: 365
      authorizedPartnersList: [
        {
          partnerRegistrationImmutableId: graphPartnerRegistrationId
          partnerName: 'MicrosoftGraphAPI'
          authorizationExpirationTimeInUtc: dateTimeAdd(nowUtc, 'P365D')
        }
      ]
    }
  }
}

output partnerConfigurationName string = createGraphPartnerConfiguration ? partnerConfiguration.name : 'default'
