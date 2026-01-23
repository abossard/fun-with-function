#!/bin/bash
# ============================================================
# Setup Microsoft Graph Change Notifications → Event Grid Partner Topic
# 
# Prerequisites:
# - Azure CLI logged in
# - Microsoft Graph CLI extension: az extension add --name microsoft-graph
# - App Registration with User.Read.All permission (admin consented)
# ============================================================

set -e

# Configuration - Update these values
RESOURCE_GROUP="${RESOURCE_GROUP:-anbo-ints-usecase-3}"
LOCATION="${LOCATION:-swedencentral}"
PREFIX="${PREFIX:-anb888}"
PARTNER_TOPIC_NAME="${PREFIX}-graph-users-topic"
GRAPH_APP_CLIENT_ID="${GRAPH_APP_CLIENT_ID:-bebcf6cd-b423-454d-a4a6-3cfd9d107886}"

# Get Azure subscription ID
AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "==========================================="
echo "Graph API Change Notifications Setup"
echo "==========================================="
echo "Subscription: $AZURE_SUBSCRIPTION_ID"
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "Partner Topic: $PARTNER_TOPIC_NAME"
echo "Graph App: $GRAPH_APP_CLIENT_ID"
echo ""

# Step 1: Create Event Grid Partner Configuration (authorize Microsoft Graph as partner)
echo "Step 1: Creating Event Grid Partner Configuration..."

# Microsoft Graph Partner Registration ID (well-known)
GRAPH_PARTNER_REGISTRATION_ID="c02e0126-707c-436d-b6a1-175d2748fb58"

# Check if partner configuration exists
EXISTING_CONFIG=$(az eventgrid partner configuration show \
  --resource-group "$RESOURCE_GROUP" \
  --query "partnerAuthorization.authorizedPartnersList[?partnerRegistrationImmutableId=='$GRAPH_PARTNER_REGISTRATION_ID']" \
  -o tsv 2>/dev/null || echo "")

if [ -z "$EXISTING_CONFIG" ]; then
  echo "Creating partner configuration..."
  # First create the partner configuration if it doesn't exist
  az eventgrid partner configuration create \
    --resource-group "$RESOURCE_GROUP" \
    --default-maximum-expiration-time-in-days 365 \
    --output none 2>/dev/null || true
  
  # Calculate authorization expiration (1 year from now)
  AUTH_EXPIRATION=$(date -u -v+365d +"%Y-%m-%d" 2>/dev/null || date -u -d "+365 days" +"%Y-%m-%d")
  
  # Then authorize Microsoft Graph as a partner
  az eventgrid partner configuration authorize \
    --resource-group "$RESOURCE_GROUP" \
    --partner-registration-immutable-id "$GRAPH_PARTNER_REGISTRATION_ID" \
    --authorization-expiration-date "$AUTH_EXPIRATION" \
    --output none
  echo "Partner configuration created."
else
  echo "Partner configuration already exists."
fi

# Step 2: Get access token for Microsoft Graph
echo ""
echo "Step 2: Getting access token for Microsoft Graph..."

# Get token using the App Registration (via federated credential with UAMI)
# For CLI, we use the current user's token
GRAPH_TOKEN=$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

# Calculate expiration (max 3 days for user resources, use 2 days to be safe)
EXPIRATION_DATE=$(date -u -v+2d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+2 days" +"%Y-%m-%dT%H:%M:%SZ")

# Step 3: Create Microsoft Graph Subscription
echo ""
echo "Step 3: Creating Microsoft Graph subscription for user changes..."

NOTIFICATION_URL="EventGrid:?azuresubscriptionid=${AZURE_SUBSCRIPTION_ID}&resourcegroup=${RESOURCE_GROUP}&partnertopic=${PARTNER_TOPIC_NAME}&location=${LOCATION}"

# Create the Graph subscription
GRAPH_SUBSCRIPTION_RESPONSE=$(curl -s -X POST \
  "https://graph.microsoft.com/v1.0/subscriptions" \
  -H "Authorization: Bearer $GRAPH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"changeType\": \"created,updated,deleted\",
    \"notificationUrl\": \"$NOTIFICATION_URL\",
    \"lifecycleNotificationUrl\": \"$NOTIFICATION_URL\",
    \"resource\": \"users\",
    \"expirationDateTime\": \"$EXPIRATION_DATE\",
    \"clientState\": \"${PREFIX}-secret-state\"
  }")

echo "Graph API Response:"
echo "$GRAPH_SUBSCRIPTION_RESPONSE" | jq .

# Check for errors
if echo "$GRAPH_SUBSCRIPTION_RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
  echo ""
  echo "ERROR: Failed to create Graph subscription."
  echo "Make sure you have User.Read.All permission and admin consent."
  exit 1
fi

GRAPH_SUBSCRIPTION_ID=$(echo "$GRAPH_SUBSCRIPTION_RESPONSE" | jq -r '.id')
echo ""
echo "Graph Subscription ID: $GRAPH_SUBSCRIPTION_ID"

# Step 4: Activate the Partner Topic
echo ""
echo "Step 4: Activating partner topic..."

# Wait for partner topic to be created
echo "Waiting for partner topic to be provisioned..."
sleep 10

# Activate the partner topic
az eventgrid partner topic activate \
  --name "$PARTNER_TOPIC_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --output none 2>/dev/null || echo "Partner topic activation may have already been done or is pending."

# Step 5: Create Event Subscription to route to Storage Queue
echo ""
echo "Step 5: Creating event subscription to Storage Queue..."

STORAGE_ACCOUNT_NAME="${PREFIX}storage"
QUEUE_NAME="hr-user-changes-q"
STORAGE_RESOURCE_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}"

# Get UAMI resource ID for delivery identity
UAMI_RESOURCE_ID=$(az identity show \
  --name "${PREFIX}-uami" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

# Create event subscription with managed identity delivery
az eventgrid partner topic event-subscription create \
  --name "${PREFIX}-user-changes-sub" \
  --partner-topic-name "$PARTNER_TOPIC_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --endpoint-type "storagequeue" \
  --endpoint "${STORAGE_RESOURCE_ID}/queueServices/default/queues/${QUEUE_NAME}" \
  --delivery-identity-endpoint-type "storagequeue" \
  --delivery-identity "UserAssigned" \
  --user-assigned-identity "$UAMI_RESOURCE_ID" \
  --output none 2>/dev/null || echo "Event subscription creation may require partner topic to be active first."

echo ""
echo "==========================================="
echo "Setup Complete!"
echo "==========================================="
echo ""
echo "Partner Topic: $PARTNER_TOPIC_NAME"
echo "Graph Subscription ID: $GRAPH_SUBSCRIPTION_ID"
echo "Expiration: $EXPIRATION_DATE"
echo ""
echo "IMPORTANT: Graph subscriptions for 'users' expire after max 3 days."
echo "You need to renew the subscription before it expires."
echo ""
echo "To renew, run:"
echo "  curl -X PATCH https://graph.microsoft.com/v1.0/subscriptions/$GRAPH_SUBSCRIPTION_ID \\"
echo "    -H 'Authorization: Bearer \$TOKEN' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"expirationDateTime\": \"<new-date>\"}'"
echo ""
echo "To list Graph subscriptions:"
echo "  curl https://graph.microsoft.com/v1.0/subscriptions -H 'Authorization: Bearer \$TOKEN'"
