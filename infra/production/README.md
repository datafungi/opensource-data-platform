# Production Infrastructure

Production infrastructure belongs here once a deployment path is ready to move
beyond lab practice.

## Layout

```text
infra/production/
├── single-cloud/   # One-cloud production baselines
├── multi-cloud/    # Cross-cloud production baselines
└── stacks/         # Runtime stack patterns shared by production targets
```

## Principles

- Keep production baselines separate from `infra/labs/`.
- Prefer reusable modules only after the first production target exposes real
  duplication.
- Keep provider-specific infrastructure under `single-cloud/` or `multi-cloud/`.
- Keep runtime orchestration patterns under `stacks/` when they can apply to
  more than one cloud target.
- Document state backend, secrets handling, access model, backup model, and
  operational runbooks before treating a setup as production-ready.

## Status

These directories are placeholders. Add concrete Terraform, Helm, Compose,
Ansible, or GitOps files only when the production target is defined.
