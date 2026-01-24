# Microsoft Graph Change Notifications → Event Grid → Storage Queue

This guide covers how the repo wires Microsoft Graph change notifications into an Event Grid partner topic, routes them to a Storage Queue, and processes them with the `process-user-changes` queue-triggered function. It also explains the two deployment options (Function-managed vs. Bicep-managed event subscriptions) and how the partner configuration is shared across function apps in the same resource group.

## Architecture at a glance

1. **Graph subscription** publishes user change notifications to Event Grid using the `EventGrid:` notification URL scheme.
2. **Event Grid partner topic** is created automatically by Graph when the subscription is created.
3. **Partner topic activation** enables routing.
4. **Event subscription** on the partner topic delivers CloudEvents to a Storage Queue using a managed identity.
5. **Queue-triggered function** processes changes and (optionally) renews subscriptions on lifecycle events.

## Required Azure resources

The app Bicep template (`infra/app.bicep`) provisions:

- A **User-Assigned Managed Identity (UAMI)** used by the Function App and as the Event Grid delivery identity.
- A **Storage Queue** (`hr-user-changes-q`) for Graph notifications.
- **Role assignments**:
  - `Storage Queue Data Message Sender` (Event Grid delivery to queue)
  - `Event Grid EventSubscription Contributor` (for the Function to create event subscriptions on partner topics)
- **Event Grid Partner Configuration** (optional, created once per resource group)

### Shared partner configuration (resource-group scope)
Event Grid Partner Configuration is a **resource-group scoped** setting. It should be created once and shared across all function apps in that resource group.

In this repo the shared resources live in `infra/rg-shared.bicep`, while the app-specific resources live in `infra/app.bicep`. Deploy the shared template **once per resource group**, then deploy the app template **once per function app**.

**Once per resource group**
- `infra/rg-shared.bicep` (partner configuration)

**Once per function app**
- `infra/app.bicep` (Function App + UAMI + Storage + Cosmos + Event Grid system topic + optional partner-topic event subscription)

## Function-managed setup (recommended)

The PowerShell worker’s `profile.ps1` runs on cold start, even on Flex Consumption. It is used to:

1. Acquire a Microsoft Graph token using the Function’s managed identity via federated credentials.
2. Discover/renew the existing `users` Graph subscription.
3. Ensure the Event Grid partner topic has an event subscription that targets the queue (`hr-user-changes-q`) using the managed identity.
4. Create a Graph subscription if none exists and activate the partner topic.

This path is recommended because the Graph subscription (and the partner topic it creates) is time-bound and needs renewal. The queue-triggered function `process-user-changes` also handles lifecycle events like `SubscriptionReauthorizationRequired`.

### Key app settings
The Function App is configured with (see `infra/app.bicep`):

- `GRAPH_PARTNER_TOPIC_NAME`: Shared partner topic name (default `graph-users-topic`).
- `GRAPH_PARTNER_EVENT_SUB_NAME`: Event subscription name (default `${prefix}-graph-users-queue-sub`).
- `GRAPH_USER_CHANGES_QUEUE_NAME`: Queue name (default `hr-user-changes-q`).
- `MANAGED_IDENTITY_RESOURCE_ID`: Needed for Event Grid delivery with a user-assigned identity.

## Bicep-managed event subscription (optional)

If you prefer infrastructure-only creation of the Event Grid subscription, set:

- `createGraphPartnerTopicEventSubscription = true`

This adds an event subscription resource under the **existing** partner topic. **Important:** the partner topic must already exist, which only happens after the Graph subscription is created. That means the usual flow is:

1. Deploy `infra/rg-shared.bicep` **once** per resource group.
2. Deploy the Function App (`infra/app.bicep`) so `profile.ps1` creates the Graph subscription (which causes the partner topic to appear).
3. Re-deploy the app template with `createGraphPartnerTopicEventSubscription = true` if you want Bicep to manage the queue subscription.

If you skip step 2, the Bicep deployment will fail because the partner topic does not exist yet.

## Graph subscription details

When creating a Graph subscription for user changes:

- Use `resource = "users"` and `changeType = "created,updated,deleted"`.
- Use the Event Grid scheme in `notificationUrl` and `lifecycleNotificationUrl`:

```
EventGrid:?azuresubscriptionid=<SUB_ID>&resourcegroup=<RG>&partnertopic=<TOPIC_NAME>&location=<LOCATION>
```

- `expirationDateTime` for `users` has a **maximum of 3 days**, so set a shorter window (the code uses 2 days) and renew.
- The queue-triggered function listens for `Microsoft.Graph.SubscriptionReauthorizationRequired` to renew automatically.

## When to use which approach

- **Function-managed (recommended):**
  - Best when you want automatic Graph subscription creation/renewal.
  - Works well with Flex Consumption because `profile.ps1` runs on cold start.

- **Bicep-managed event subscription:**
  - Useful for stricter infra-as-code policies.
  - Requires a two-step deployment because the partner topic is created by Graph.

## Troubleshooting tips

- If the queue isn’t receiving events, verify:
  - The partner topic is **Activated**.
  - The event subscription exists and uses the user-assigned identity.
  - The UAMI has `Storage Queue Data Message Sender` on the storage account.
- If Graph subscription renewal fails, check `process-user-changes` logs and confirm the managed identity federation is correctly configured.
