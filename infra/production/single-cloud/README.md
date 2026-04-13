# Single-Cloud Production

Use this area for production baselines that target one cloud provider at a time.

```text
single-cloud/
├── azure/
├── aws/
└── gcp/
```

Each provider directory should define its own state backend, network baseline,
identity model, secrets integration, compute/runtime layer, storage layer,
observability, backup strategy, and disaster recovery notes.
