## Architecture overview
- Logic App (Consumption) ingests emails, writes metadata + attachments to Blob Storage under `emails/{correlationId}/`
- Blob-triggered Function (Flex Consumption, PowerShell 7.4) fires only for `emails/{correlationId}/metadata.json` and writes Cosmos DB docs (pk = sender email `/pk`)
- Event Grid subscription (Managed Identity delivery) sends attachment BlobCreated events to a Storage Queue for decoupled attachment handling
- Attachment queue processor (PowerShell) logs/handles attachment events
- Single User-Assigned Managed Identity (UAMI) applied to Function App, used for Event Grid delivery, and enabled on Logic App; data-plane access uses MI (roles: Storage Blob Data Contributor + Queue Data Contributor, Cosmos DB Data Contributor as needed)
- Application Insights enabled for the Function App
### Message flow
```
Email --> Logic App --> Blob Storage (metadata.json + attachments)
        metadata.json --> Blob Trigger Function -> Cosmos DB
        attachments/* --> Event Grid (MI delivery) -> Storage Queue -> Attachment handler
```

## Iterative Portal To-Do
1. Create/choose Resource Group and Storage Account; add blob container `emails`
2. Create UAMI; grant Storage Blob Data Reader/Contributor (as needed) and Cosmos DB Data Contributor
3. Create Logic App (Consumption); enable user-assigned MI; add Outlook "When a new email arrives (V3)" trigger; build `correlationId` (GUID); write metadata.json + attachments to `emails/{correlationId}/...` using MI auth to Storage
4. Create Storage Queue `hr-attachments-q`
5. Create Event Grid subscription on the Storage Account for attachments:
   - Event type: BlobCreated
   - Endpoint: Storage Queue `hr-attachments-q`
   - Filters: subject begins `/blobServices/default/containers/emails/blobs/emails/` and ends `/attachments/`
   - Delivery identity: use the UAMI
6. Create Function App (Flex Consumption, Linux, PowerShell 7.4) with Application Insights; assign the UAMI
7. Deploy functions:
   - `process-queue` (blob trigger on `emails/{correlationId}/metadata.json`) upserts into Cosmos DB
   - `process-attachments` (queue trigger for `hr-attachments-q`) logs/handles attachments
8. Create Cosmos DB account (SQL API), database `hrdb`, container `emails`, partition key `/pk`
9. Test end-to-end with sample email; verify Cosmos DB document and logs

## Minimal Function Code (PowerShell 7.4)
- Files: `FunctionApp/process-queue/run.ps1`, `FunctionApp/process-queue/function.json` (blob trigger), `FunctionApp/process-attachments/*`
- Config: `host.json` with extension bundle; modules downloaded locally via `fetch-modules.ps1`

## Azure CLI provisioning (script below)

## Testing
1. Send a test email; Logic App writes metadata.json + attachments
2. Confirm blob path `emails/{correlationId}/metadata.json`
3. Verify attachment events arrive in `hr-attachments-q`
4. Check blob-trigger Function invocation; confirm Cosmos DB `emails` container has document with `pk=fromEmail` and `correlationId`
5. Inspect Application Insights traces for correlationId
