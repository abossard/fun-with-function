# Graph change notification → Event Grid flow

```mermaid
sequenceDiagram
    autonumber
    participant User as Admin/User
    participant Setup as setup.ps1
    participant App as Function App (profile.ps1/S0)
    participant UAMI as UAMI (federated)
    participant Graph as Microsoft Graph
    participant ARM as Azure Resource Manager
    participant EG as Event Grid Partner Topic
    participant Queue as Storage Queue
    participant Worker as process-user-changes

    User->>Setup: Deploy infra (rg-shared + app)
    Setup->>ARM: Create resources + role assignments

    App->>UAMI: Request federated assertion
    UAMI-->>App: Assertion token
    App->>Graph: POST /subscriptions (EventGrid: notificationUrl)
    Graph-->>EG: Create partner topic (eventual consistency)

    App->>ARM: PATCH partner topic activation
    ARM-->>EG: Activate partner topic

    App->>ARM: PUT partnerTopics/eventSubscriptions
    ARM-->>EG: Create event subscription

    Graph-->>EG: Publish change notifications
    EG-->>Queue: Deliver CloudEvents via UAMI
    Queue-->>Worker: Trigger processing
    Worker->>Graph: Renew subscription on lifecycle events
```

## Notes
- The partner topic is created by Microsoft Graph when the subscription uses the EventGrid notification URL.
- Partner topic creation is eventually consistent; retries may be needed before activation/subscription succeed.
- The Function App uses a managed identity to call Graph and ARM.
