# GlusterFS Storage For Docker Swarm

This guide configures GlusterFS as shared storage for the Docker Swarm cluster
created by this Terraform project.

## Current Cluster

| Node             | Private IP   | Role                    | Existing data disk |
|------------------|--------------|-------------------------|--------------------|
| `vm-01-control`  | `10.10.1.10` | Swarm manager / control | `/data`            |
| `vm-02-worker-a` | `10.10.1.11` | Swarm worker            | `/data`            |
| `vm-03-worker-b` | `10.10.1.12` | Swarm worker            | `/data`            |

The Azure network security group allows all traffic inside the virtual network,
so GlusterFS traffic between these VMs does not need an extra Azure NSG rule.

## Storage Layout

Use one replicated GlusterFS volume across the three VM data disks:

```text
Brick path on each VM:   /data/gluster/brick1/swarm
Gluster volume name:     swarm
Client mount on each VM: /mnt/gluster/swarm
Docker shared path:      /mnt/gluster/swarm/services/<service-name>
```

Keep Docker's engine data on local disk. This project configures Docker with
`"data-root": "/data/docker"` in cloud-init, which should stay local to each
node. Use GlusterFS only for application data that must be available from any
Swarm node.

With 3-way replication, usable capacity is approximately one node's available
brick capacity, not the sum of all three disks.

## Good And Bad Fits

Good uses for GlusterFS in this lab:

- Airflow DAGs
- Lightweight app uploads
- Shared service configuration
- Grafana data for a single replica
- Small Docker service state that can tolerate network filesystem latency

Avoid GlusterFS for write-heavy database storage unless the goal is explicitly
to experiment with failure modes. Prefer local disks plus application-native
replication or backups for PostgreSQL, ClickHouse, Cassandra, MongoDB, and
Prometheus data.

## 1. Add Host Mappings

Run on every VM:

```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'
10.10.1.10 vm-01-control
10.10.1.11 vm-02-worker-a
10.10.1.12 vm-03-worker-b
EOF

getent hosts vm-01-control vm-02-worker-a vm-03-worker-b
```

## 2. Install GlusterFS

Run on every VM:

```bash
sudo apt-get update
sudo apt-get install -y glusterfs-server glusterfs-client
sudo systemctl enable --now glusterd
sudo systemctl status glusterd --no-pager
```

If `ufw` is active, allow GlusterFS from the VM subnet:

```bash
sudo ufw allow from 10.10.1.0/24 to any port 24007 proto tcp
sudo ufw allow from 10.10.1.0/24 to any port 24008 proto tcp
sudo ufw allow from 10.10.1.0/24 to any port 49152:49251 proto tcp
```

Skip the `ufw` commands when `sudo ufw status` reports `inactive`.

## 3. Create Brick And Mount Directories

Run on every VM:

```bash
findmnt /data
df -h /data

sudo mkdir -p /data/gluster/brick1/swarm
sudo mkdir -p /mnt/gluster/swarm
```

`/data` should be the attached Azure managed data disk, not the OS disk.

## 4. Build The Trusted Pool

Run only on `vm-01-control`:

```bash
sudo gluster peer probe vm-02-worker-a
sudo gluster peer probe vm-03-worker-b
sudo gluster peer status
```

The two worker nodes should show as connected peers.

## 5. Create The Replicated Volume

Run only on `vm-01-control`:

```bash
sudo gluster volume create swarm replica 3 transport tcp \
  vm-01-control:/data/gluster/brick1/swarm \
  vm-02-worker-a:/data/gluster/brick1/swarm \
  vm-03-worker-b:/data/gluster/brick1/swarm

sudo gluster volume start swarm
sudo gluster volume status swarm
sudo gluster volume info swarm
```

Optional lab-friendly settings:

```bash
sudo gluster volume set swarm network.ping-timeout 10
sudo gluster volume set swarm cluster.server-quorum-type server
sudo gluster volume set swarm performance.cache-size 256MB
```

## 6. Mount The Volume On Every VM

Run on every VM:

```bash
sudo mount -t glusterfs vm-01-control:/swarm /mnt/gluster/swarm
df -h /mnt/gluster/swarm
```

Persist the mount:

```bash
echo 'vm-01-control:/swarm /mnt/gluster/swarm glusterfs defaults,_netdev,backupvolfile-server=vm-02-worker-a,backupvolfile-server=vm-03-worker-b 0 0' | sudo tee -a /etc/fstab
```

Test the fstab entry:

```bash
sudo umount /mnt/gluster/swarm
sudo mount -a
findmnt /mnt/gluster/swarm
```

## 7. Verify Replication

On `vm-01-control`:

```bash
echo "hello from control $(date)" | sudo tee /mnt/gluster/swarm/replication-test.txt
```

On `vm-02-worker-a` and `vm-03-worker-b`:

```bash
cat /mnt/gluster/swarm/replication-test.txt
```

Check heal status from `vm-01-control`:

```bash
sudo gluster volume heal swarm info
```

## 8. Use The Shared Path From Swarm

Docker Swarm can schedule a task on any eligible node. For bind mounts, the
source path must exist on every node. The shared GlusterFS mount at
`/mnt/gluster/swarm` satisfies that requirement.

Create a test directory and service:

```bash
sudo mkdir -p /mnt/gluster/swarm/services/nginx-html
echo '<h1>Hello from GlusterFS-backed Swarm storage</h1>' | sudo tee /mnt/gluster/swarm/services/nginx-html/index.html

docker service create \
  --name nginx-gluster-test \
  --replicas 2 \
  --publish published=8080,target=80 \
  --mount type=bind,source=/mnt/gluster/swarm/services/nginx-html,target=/usr/share/nginx/html,readonly \
  nginx:latest
```

Verify:

```bash
docker service ps nginx-gluster-test
curl http://127.0.0.1:8080
```

Remove the test service:

```bash
docker service rm nginx-gluster-test
```

## 9. Stack File Example

Example Swarm stack service using the GlusterFS mount:

```yaml
services:
  grafana:
    image: grafana/grafana:latest
    volumes:
      - type: bind
        source: /mnt/gluster/swarm/services/grafana
        target: /var/lib/grafana
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
```

Prepare the path before deployment:

```bash
sudo mkdir -p /mnt/gluster/swarm/services/grafana
sudo chown -R 472:472 /mnt/gluster/swarm/services/grafana
docker stack deploy -c stack.yml lab
```

Keep most writable services at `replicas: 1` unless the application is safe for
multiple writers against the same filesystem path.

## 10. Operations

Useful status checks:

```bash
sudo gluster peer status
sudo gluster volume status swarm
sudo gluster volume heal swarm info
df -h /mnt/gluster/swarm
mount | grep gluster
docker node ls
docker service ls
```

After VM reboot or Azure deallocation, check that GlusterFS is healthy before
starting write-heavy services:

```bash
sudo systemctl status glusterd --no-pager
findmnt /mnt/gluster/swarm
sudo gluster volume status swarm
sudo gluster volume heal swarm info
```

The lab shutdown automation can deallocate all VMs. That is acceptable when the
whole cluster stops together, but do not intentionally deallocate one GlusterFS
node while workloads are actively writing unless you are testing recovery.
