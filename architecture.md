## Architecture overview
- Logic App (Consumption) ingests emails, writes metadata + attachments to Blob Storage under `emails/{correlationId}/`
- Event Grid subscription on BlobCreated with subject filters publishes only `metadata.json` blobs to Storage Queue
- Queue decouples and triggers PowerShell Azure Function (Flex Consumption) to process metadata
- Function upserts a document into Cosmos DB (SQL API, pk = sender email `/pk`)
- Application Insights enabled for the Function App

### Message flow
```
Email --> Logic App --> Blob Storage (metadata.json + attachments)
      \-> Event Grid (filtered on metadata.json) -> Storage Queue -> Azure Function -> Cosmos DB
```

## Iterative Portal To-Do
1. Create Resource Group and Storage Account; add blob container `emails`
2. Create Logic App (Consumption); add Outlook "When a new email arrives (V3)" trigger
3. In Logic App, build `correlationId` (GUID), write metadata.json + attachments to `emails/{correlationId}/...`
4. Create Storage Queue `hr-ingest-q`
5. Create Event Grid subscription on the Storage Account:
   - Event type: BlobCreated
   - Endpoint: Storage Queue `hr-ingest-q`
   - Filters: subject begins `/blobServices/default/containers/emails/blobs/emails/` and ends `/metadata.json`
6. Create Function App (Flex Consumption, Linux, PowerShell 7.4) with Application Insights; configure `AzureWebJobsStorage` and `CosmosDBConnection`
7. Deploy function code from `FunctionApp/process-queue`
8. Create Cosmos DB account (SQL API), database `hrdb`, container `emails`, partition key `/pk`
9. Test end-to-end with sample email; verify Cosmos DB document and logs

## Minimal Function Code (PowerShell 7.4)
- Files: `FunctionApp/process-queue/run.ps1`, `FunctionApp/process-queue/function.json`
- Config: `host.json` with extension bundle, `requirements.psd1` for Az modules

## Azure CLI provisioning (script below)

## Testing
1. Send a test email; Logic App writes metadata.json + attachments
2. Confirm blob path `emails/{correlationId}/metadata.json`
3. Verify queue message created (Event Grid filter)
4. Check Function invocation; confirm Cosmos DB `emails` container has document with `pk=fromEmail` and `correlationId`
5. Inspect Application Insights traces for correlationId
