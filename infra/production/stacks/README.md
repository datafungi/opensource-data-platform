# Production Runtime Stacks

Runtime stack patterns that may be reused across production targets belong here.

```text
stacks/
├── docker-swarm/
└── kubernetes/
```

Keep cloud-specific infrastructure outside this directory. Stack definitions here
should focus on application runtime concerns: service layout, secrets injection,
storage contracts, ingress, health checks, observability, and deployment flow.
