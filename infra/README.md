# Infrastructure

Infrastructure is grouped by intent rather than by tool.

## Layout

```text
infra/
├── docker/        # Local Docker Compose services used by the development workflow
├── labs/
│   └── azure/    # Azure VM-based practice lab
└── production/   # Production infrastructure placeholders
```

Use `labs/` for disposable or practice environments. Use `production/` for
environments intended to become durable deployment baselines. Production is
split into single-cloud, multi-cloud, and reusable runtime stack placeholders.
