# fun-with-function
Example on how to use the Azure Integration Services

## Run locally
### Prerequisites
- Azure Functions Core Tools v4
- PowerShell 7.x (tested with 7.4)
- Node.js 18+ (for Azurite)
- Azurite (local Storage emulator)

### 1) Start Azurite (Storage emulator)
Run this from the repo root:

```
npx azurite --location ./azurite --silent
```

### 2) Create local settings
Create a file at FunctionApp/local.settings.json:

```json
{
	"IsEncrypted": false,
	"Values": {
		"AzureWebJobsStorage": "UseDevelopmentStorage=true",
		"FUNCTIONS_WORKER_RUNTIME": "powershell",
		"DISABLE_COSMOS_OUTPUT": "true"
	}
}
```

> Set `DISABLE_COSMOS_OUTPUT=false` and provide a real `CosmosDBConnection` value if you want to write to Cosmos DB locally or in Azure.

### 3) Start Functions
From the repo root:

```
func start --script-root FunctionApp
```

### 4) Generate a test payload
```
curl http://localhost:7071/api/test/generate/test-123
```

This writes:
- Blob: `emails/test-123/metadata.json`
- Blob: `emails/test-123/attachments/fake.txt`
- Queue message: `hr-attachments-q`

### Notes
- The Functions runtime will usually auto-create the `emails` container and `hr-attachments-q` queue when using Azurite. If it doesn’t, create them manually via Azure Storage Explorer or the Azurite API.
