# Azure Lab

This lab provisions a small Azure VM-based environment for practicing data
infrastructure deployment.

## Contents

```text
infra/labs/azure/
├── terraform/    # Azure resources, VM bootstrap, cost controls
├── docs/         # Lab user guides
└── scripts/      # Azure VM start and deallocate helpers
```

## Current Shape

- 3 Ubuntu VMs: `vm-01-control`, `vm-02-worker-a`, `vm-03-worker-b`
- Static private IPs in `10.10.1.0/24`
- Docker and Tailscale installed by cloud-init
- Optional Dokploy install on `vm-01-control`
- Docker Swarm storage guide using GlusterFS
- Daily shutdown and inactivity-based deallocation controls

Start with [terraform/README.md](terraform/README.md), then use
[docs/glusterfs-swarm-storage.md](docs/glusterfs-swarm-storage.md) after Docker
Swarm is running.
