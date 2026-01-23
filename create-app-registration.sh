#!/bin/bash
# Creates an App Registration with Directory.Read.All permission
# Usage: ./create-app-registration.sh <app-name>

set -e

APP_NAME="${1:-hr-integration-app}"

echo "Creating App Registration: $APP_NAME"

# Create the app registration
APP_ID=$(az ad app create \
  --display-name "$APP_NAME" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)

echo "App Registration created with Client ID: $APP_ID"

# Get the Object ID of the app
APP_OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)

# Microsoft Graph API well-known ID
GRAPH_API_ID="00000003-0000-0000-c000-000000000000"

# Directory.Read.All app role ID (application permission)
DIRECTORY_READ_ALL_ID="7ab1d382-f21e-4acd-a863-ba3e13f7da61"

# Add Directory.Read.All permission (requires admin consent)
az ad app permission add \
  --id "$APP_ID" \
  --api "$GRAPH_API_ID" \
  --api-permissions "$DIRECTORY_READ_ALL_ID=Role"

echo "Added Directory.Read.All permission (requires admin consent)"

# Create service principal for the app
SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv 2>/dev/null || \
  az ad sp show --id "$APP_ID" --query id -o tsv)

echo "Service Principal created/found: $SP_ID"

# Grant admin consent (requires appropriate permissions)
echo ""
echo "Granting admin consent..."
az ad app permission admin-consent --id "$APP_ID" 2>/dev/null && \
  echo "Admin consent granted" || \
  echo "⚠️  Admin consent failed - you may need to grant it manually in Azure Portal"

echo ""
echo "=========================================="
echo "App Registration Details:"
echo "=========================================="
echo "Display Name:    $APP_NAME"
echo "Client ID:       $APP_ID"
echo "Object ID:       $APP_OBJECT_ID"
echo "SP Object ID:    $SP_ID"
echo ""
echo "To add federated credential, run:"
echo "az ad app federated-credential create --id $APP_ID --parameters federated-credential.json"
echo ""
echo "federated-credential.json template:"
cat << EOF
{
  "name": "uami-federation",
  "issuer": "<UAMI_ISSUER>",
  "subject": "<UAMI_SUBJECT>",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "Federation with User-Assigned Managed Identity"
}
EOF
echo ""
echo "Get federation params from setup.ps1 output after deployment"
