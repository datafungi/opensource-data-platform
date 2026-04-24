# Data Platform Security

## 1. Network Access

### 1.1 Access Model

All access to the cluster is routed through a dedicated Tailscale VM that acts as a subnet router
and VPN exit node. The cluster nodes have no publicly reachable management or UI ports — all traffic
must traverse the tailnet.

```
[Tailnet device]
      │  WireGuard (UDP 41641)
      ▼
[Tailscale VM — 10.54.0.4]            tailscale-subnet: 10.54.0.0/24
Subnet router: advertises 10.54.0.0/16 to the tailnet
      │  VNet-internal routing
      ▼
[Cluster nodes — 10.54.1.10–12]       nodes-subnet: 10.54.1.0/24
  node-1 (10.54.1.10) — Swarm manager, has public IP
  node-2 (10.54.1.11) — Swarm worker
  node-3 (10.54.1.12) — Swarm worker
```

Any device enrolled in the tailnet can reach cluster nodes after the advertised routes are approved
in the Tailscale admin console (Machines → node → Edit route settings).

The Tailscale VM is excluded from the cluster auto-shutdown schedule — it must stay running to keep
VNet reachability via tailnet at all times. It retrieves its auth key from Key Vault at boot via
managed identity; no secrets are stored in cloud-init or VM user data.

### 1.2 NSG Rules

**nodes-nsg** (nodes-subnet: 10.54.1.0/24)

| Rule                       | Port            | Source       | Purpose                      |
|----------------------------|-----------------|--------------|------------------------------|
| Allow-Airflow-UI           | 8080 TCP        | 10.54.0.0/24 | UI access via Tailscale only |
| Allow-Grafana              | 3000 TCP        | 10.54.0.0/24 | UI access via Tailscale only |
| Allow-Portainer            | 9443 TCP        | 10.54.0.0/24 | UI access via Tailscale only |
| Allow-SSH-Tailscale        | 22 TCP          | 10.54.0.0/24 | SSH via tailnet              |
| Allow-Swarm-Manager-TCP    | 2377 TCP        | 10.54.1.0/24 | Swarm cluster management     |
| Allow-Swarm-Discovery      | 7946 TCP+UDP    | 10.54.1.0/24 | Swarm gossip                 |
| Allow-Swarm-Overlay        | 4789 UDP        | 10.54.1.0/24 | VXLAN overlay network        |
| Allow-GlusterFS-Management | 24007–24008 TCP | 10.54.1.0/24 | GlusterFS management         |
| Allow-GlusterFS-Bricks     | 49152–49200 TCP | 10.54.1.0/24 | GlusterFS brick replication  |
| Deny-All-Inbound           | *               | *            | Default deny                 |

The UI ports (8080, 3000, 9443) source is conditional in Terraform: `10.54.0.0/24` when
`enable_tailscale = true`, `Internet` when false. With Tailscale enabled, these services are
unreachable from the public internet.

**tailscale-nsg** (tailscale-subnet: 10.54.0.0/24)

| Rule                      | Port      | Source         | Purpose                                   |
|---------------------------|-----------|----------------|-------------------------------------------|
| Allow-Tailscale-WireGuard | 41641 UDP | Internet       | Direct peer-to-peer WireGuard connections |
| Allow-SSH-VNet            | 22 TCP    | VirtualNetwork | VNet-internal SSH only                    |
| Deny-All-Inbound          | *         | *              | Default deny                              |
