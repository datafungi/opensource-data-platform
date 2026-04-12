# Azure Data Infrastructure Lab

This Terraform project provisions a small Azure lab environment for practicing
data infrastructure deployment and infrastructure as code.

## Target Design

- Region: Southeast Asia
- Budget model: Azure subscription with monthly credit
- Compute: 3 Linux VMs
- VM size: `Standard_D4as_v5`
- Network: all VMs share one private virtual network
- Access: expose as little as possible publicly; prefer one locked-down SSH
  entry point or a bastion-style access pattern
- Outbound: NAT Gateway provides explicit outbound internet access; implicit
  default outbound access is disabled on the VM subnet

## Workloads

The VM cluster is intended to host these services:

- Airflow as the primary pipeline orchestrator
- Dagster for occasional orchestration experiments
- Redis for Airflow CeleryExecutor
- PostgreSQL
- ClickHouse cluster
- Cassandra cluster
- MongoDB
- OpenMetadata
- Prometheus and Grafana

## Azure Resources

Core resources:

- Resource group
- Virtual network
- VM subnet
- NAT Gateway with a static outbound public IP
- Network security group
- Network interfaces with stable private IPs
- 3 Linux virtual machines
- Managed OS disks
- Managed data disks for database and service storage
- Storage account and blob container for Terraform remote state
- Key Vault for secrets, credentials, and generated keys

Cost and operations resources:

- Daily VM shutdown schedule
- Automation account for inactivity-based VM deallocation
- Managed identity for shutdown automation
- Role assignment allowing the automation identity to stop/deallocate VMs
- Automation schedule for hourly inactivity checks
- Budget alerts for the subscription

Optional resources:

- Public IP for a single jump host
- NAT Gateway can be disabled with `enable_nat_gateway = false` if you accept
  Azure default outbound access for a short-lived lab
- Azure Bastion, if stronger managed access is preferred
- Log Analytics workspace with short retention
- Network Watcher flow logs for networking practice
- Storage container for lightweight backups and exports

## VM Layout

Initial layout:

| VM               | Size               | Role                                                                   |
|------------------|--------------------|------------------------------------------------------------------------|
| `vm-01-control`  | `Standard_D4as_v5` | Airflow, Dagster, Redis, PostgreSQL, OpenMetadata, Prometheus, Grafana |
| `vm-02-worker-a` | `Standard_D4as_v5` | ClickHouse, Cassandra, MongoDB                                         |
| `vm-03-worker-b` | `Standard_D4as_v5` | ClickHouse, Cassandra, MongoDB                                         |

The layout is for hands-on practice, not production-grade isolation. Resource
pressure is expected when all services are running at the same time.

## Storage

Recommended starting point per VM:

- OS disk: 32 GiB `StandardSSD_LRS`
- Data disk: 64 GiB `StandardSSD_LRS`

Database data should live on managed data disks, not on the OS disk or temporary
local storage.

## Estimated Monthly Cost

Estimate date: 2026-04-12. Region: Southeast Asia. Currency: USD.

Assumptions:

- 3 x `Standard_D4as_v5` Linux VMs
- VMs run for 20 hours per month total
- VMs are deallocated when not in use
- No public jumpbox IP because access uses Tailscale
- NAT Gateway enabled for explicit outbound internet access
- 3 x 32 GiB Standard SSD OS disks
- 3 x 64 GiB Standard SSD data disks
- No meaningful Log Analytics ingestion
- Minimal Key Vault, Storage Account, and Automation usage

Approximate monthly cost:

| Resource                                  |             Quantity | Pricing basis                          | Estimated cost |
|-------------------------------------------|---------------------:|----------------------------------------|---------------:|
| Linux VMs, `Standard_D4as_v5`             |                    3 | `$0.216/hour x 20 hours`               |       `$12.96` |
| 32 GiB Standard SSD OS disks, E4 LRS      |                    3 | Lower Standard SSD tier                |          `~$8` |
| 64 GiB Standard SSD data disks, E6 LRS    |                    3 | `$4.80/month + $0.611/month mount`     |       `$16.23` |
| NAT Gateway and outbound public IP        |                    1 | Fixed hourly cost plus data processed  |     `~$35-$40` |
| VNet, subnet, NSG, NICs, availability set |                1 set | No direct hourly charge                |        `$0.00` |
| Public IP                                 |                    0 | Disabled for Tailscale access          |        `$0.00` |
| Storage account, hot LRS blob storage     |              Minimal | About `$0.02/GB-month` plus operations |      `< $1.00` |
| Key Vault Standard                        |              Minimal | Operation-based billing                |      `< $1.00` |
| Azure Automation                          | Hourly runbook check | Usually low for this usage             |        `$0-$5` |
| Log Analytics workspace                   |              Minimal | Ingestion-based billing                |          `$0+` |

Expected monthly total:

```text
About $75-$85/month
```

Main cost drivers:

- Managed disks continue billing while VMs are deallocated.
- VM compute only bills while VMs are running.
- NAT Gateway bills while it exists, even when VMs are deallocated.
- Log Analytics can grow quickly if VM diagnostics or application logs are sent
  there.
- Storage account cost depends on backup/export volume and operations.

If the jumpbox public IP is enabled later, add about:

```text
$0.005/hour x 730 hours = about $3.65/month
```

Increase `data_disk_size_gb` before the first apply if you expect to retain
large local datasets, ClickHouse parts, or Cassandra SSTables.

## Shutdown Strategy

The VMs should be deallocated when not in use to control cost.

- Use Azure DevTest global VM shutdown schedules for fixed daily shutdown.
- Use Azure Automation plus Azure Monitor alerts for inactivity-based shutdown.
- The inactivity automation should deallocate VMs, not only shut down the guest
  operating system.

Recommended inactivity rule:

- CPU and network activity remain below a conservative threshold for 2 hours.
- The automation account runbook deallocates all lab VMs.

For more predictable control, add a manual "lab lease" mechanism later. A lease
script can record active use, and automation can deallocate the cluster when the
lease has not been renewed.

## Implementation Notes

- Start with a simple Terraform layout before splitting into modules.
- Keep service installation separate from Azure provisioning where possible.
- Use Docker Compose or Ansible for the first version of service deployment.
- Keep Prometheus retention short to avoid unnecessary disk growth.
- Avoid managed Azure database services at first to preserve the monthly credit.

## Terraform Setup Guide

This directory currently starts as a simple Terraform project. Build it in small
steps and apply each step before moving to the next one.

### 1. Prerequisites

Install and authenticate:

```bash
az login
az account set --subscription "<subscription-id>"
terraform init
```

Confirm the active subscription before creating resources:

```bash
az account show --query "{name:name,id:id,tenantId:tenantId}" --output table
```

### 2. Configure Project Inputs

Create a local `terraform.tfvars` file:

```hcl
location       = "southeastasia"
project_name   = "datafungi-lab"
admin_username = "azureuser"
vm_size        = "Standard_D4as_v5"
ssh_public_key = "~/.ssh/id_rsa.pub"

allowed_ssh_cidrs = [
  "<your-public-ip>/32"
]
```

Do not commit secrets, private keys, or personal IP addresses.

### 3. Bootstrap Remote State

Create a small bootstrap configuration or use Azure CLI once to create:

- Resource group for Terraform state
- Storage account
- Blob container named `tfstate`

Then configure the Terraform backend:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "<state-resource-group>"
    storage_account_name = "<state-storage-account>"
    container_name       = "tfstate"
    key                  = "datafungi-lab.tfstate"
  }
}
```

Reinitialize after adding the backend:

```bash
terraform init -reconfigure
```

### 4. Create The Core Foundation

Add and apply these resources first:

- `azurerm_resource_group`
- `azurerm_virtual_network`
- `azurerm_subnet`
- `azurerm_nat_gateway`
- `azurerm_public_ip` for NAT Gateway egress
- `azurerm_network_security_group`
- `azurerm_subnet_network_security_group_association`
- `azurerm_key_vault`
- `azurerm_storage_account` for backups and exports

Recommended network shape:

```text
VNet:       10.10.0.0/16
VM subnet: 10.10.1.0/24
```

Run:

```bash
terraform fmt
terraform validate
terraform plan
terraform apply
```

### 5. Create The VM Cluster

Add the VM resources next:

- `azurerm_nat_gateway` and `azurerm_public_ip` for explicit outbound access
- `azurerm_public_ip` for one jump host, if needed
- `azurerm_network_interface` for each VM
- `azurerm_linux_virtual_machine` for each VM
- `azurerm_managed_disk` for each data disk
- `azurerm_virtual_machine_data_disk_attachment`

Use static private IPs for predictable cluster configuration:

```text
vm-01-control: 10.10.1.10
vm-02-worker-a: 10.10.1.11
vm-03-worker-b: 10.10.1.12
```

Use Ubuntu Server 24.04 LTS x64 Gen 2, SSH key authentication,
`Standard_D4as_v5`, a 32 GiB OS disk, and one 64 GiB managed data disk per
VM.

Cloud-init installs Docker and Tailscale on every VM. It installs Dokploy only
on `vm-01-control` when `install_dokploy_on_control_vm` is enabled. Tailscale
must still be authenticated after provisioning with an auth key or interactive
login.

### 6. Add Shutdown Controls

Add daily shutdown first:

- `azurerm_dev_test_global_vm_shutdown_schedule`

Then add inactivity shutdown:

- `azurerm_automation_account`
- System-assigned managed identity
- `azurerm_role_assignment` for VM stop/deallocate permissions
- Runbook that deallocates the 3 VMs
- `azurerm_monitor_action_group`
- `azurerm_monitor_metric_alert`

The runbook must deallocate VMs, not only shut down the guest operating system.

### 7. Add Basic Monitoring

Keep Azure-native monitoring small:

- `azurerm_log_analytics_workspace` with short retention
- Optional diagnostic settings for selected resources only

Use Prometheus and Grafana inside the VM cluster for service metrics.

### 8. Deploy Services

Use Terraform for Azure infrastructure only. Use a separate layer for software
installation:

- Docker Compose for the first version
- Ansible once the service layout stabilizes
- Kubernetes only after the VM-based layout is understood

Recommended order:

1. Docker and base packages
2. PostgreSQL
3. Redis
4. Airflow
5. Prometheus and Grafana
6. MongoDB
7. Cassandra
8. ClickHouse
9. OpenMetadata
10. Dagster

### 9. Validate

After each apply:

```bash
terraform output
az vm list -g "<resource-group-name>" -d --output table
```

Check:

- All 3 VMs are in Southeast Asia
- Private IPs match the expected plan
- Tailscale SSH works, or SSH is restricted to the allowed CIDR range when a
  jumpbox public IP is enabled
- The VM subnet has `default_outbound_access_enabled = false` when
  `enable_nat_gateway = true`
- Data disks are attached
- Daily shutdown schedules are enabled
- Budget alerts are configured

### 10. Stop Or Destroy

For normal cost control, deallocate:

```bash
az vm deallocate --resource-group "<resource-group-name>" --name "vm-01-control"
az vm deallocate --resource-group "<resource-group-name>" --name "vm-02-worker-a"
az vm deallocate --resource-group "<resource-group-name>" --name "vm-03-worker-b"
```

For full cleanup:

```bash
terraform destroy
```

Before destroying, export any database dumps or test data that should be kept.

Soft-delete cleanup checks after destroy:

```bash
az keyvault list-deleted --query "[?starts_with(name, 'kv-datafungi-lab')]"
az monitor log-analytics workspace list-deleted-workspaces \
  --query "[?name=='log-datafungi-lab']"
```

If a Log Analytics workspace remains recoverable, recover it, delete it with
`--force true`, then delete the temporary resource group. Key Vault purge is
handled by the AzureRM provider features block when permissions allow it.
