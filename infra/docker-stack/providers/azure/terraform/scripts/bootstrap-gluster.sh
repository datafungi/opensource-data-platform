#!/bin/bash
# bootstrap-gluster.sh
#
# Run this script from your workstation AFTER `terraform apply` completes and
# all three VMs have finished their cloud-init setup (~8-12 minutes).
#
# Prerequisites:
#   - SSH access to node-1 (via direct IP or Azure Bastion)
#   - The three VMs are online and glusterd is running on each
#   - `terraform output` values are available
#
# Usage:
#   chmod +x bootstrap-gluster.sh
#   NODE1_IP=<public_ip> ADMIN_USER=azureuser ./bootstrap-gluster.sh
#
# To verify cloud-init finished successfully on each node before running:
#   ssh azureuser@<node_ip> "sudo cloud-init status --wait && cat /var/log/node-setup.log"

set -euo pipefail

NODE1_IP="${NODE1_IP:-}"
NODE2_IP="${NODE2_IP:-10.54.1.11}"
NODE3_IP="${NODE3_IP:-10.54.1.12}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
VOLUME_NAME="${VOLUME_NAME:-data-platform-vol}"
BRICK_PATH="/data/gluster/brick"
GLUSTER_MOUNT="/mnt/gluster"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_OPTS="${SSH_OPTS:-"-o StrictHostKeyChecking=no -o ConnectTimeout=10"}"

if [ -n "$SSH_KEY_PATH" ]; then
  SSH_OPTS="-i $SSH_KEY_PATH $SSH_OPTS"
fi

# ─────────────────────────────────────────────────────────────────────────────

if [ -z "$NODE1_IP" ]; then
  echo "ERROR: NODE1_IP is required."
  echo "  Export it from Terraform: export NODE1_IP=\$(terraform output -raw node_public_ip)"
  exit 1
fi

ssh_node1() {
  ssh $SSH_OPTS "${ADMIN_USER}@${NODE1_IP}" "$@"
}

echo "==> Checking glusterd status on all nodes..."
for ip in "$NODE1_IP" "$NODE2_IP" "$NODE3_IP"; do
  ssh $SSH_OPTS "${ADMIN_USER}@${ip}" "sudo systemctl is-active glusterd" || {
    echo "ERROR: glusterd not running on $ip. Check /var/log/node-setup.log"
    exit 1
  }
done
echo "    glusterd is active on all nodes."

# ── 1. Probe peers from node-1 ────────────────────────────────────────────────
echo "==> Probing peers..."
ssh_node1 "sudo gluster peer probe $NODE2_IP"
ssh_node1 "sudo gluster peer probe $NODE3_IP"

# Wait for peer state to settle
echo "    Waiting for peer connections to stabilise..."
sleep 5

ssh_node1 "sudo gluster peer status"

# ── 2. Verify brick paths exist on all nodes ──────────────────────────────────
echo "==> Verifying brick paths..."
for ip in "$NODE1_IP" "$NODE2_IP" "$NODE3_IP"; do
  ssh $SSH_OPTS "${ADMIN_USER}@${ip}" "test -d $BRICK_PATH" || {
    echo "ERROR: Brick path $BRICK_PATH does not exist on $ip"
    exit 1
  }
done
echo "    Brick paths verified."

# ── 3. Create and start the GlusterFS volume ──────────────────────────────────
echo "==> Creating GlusterFS volume '$VOLUME_NAME' (replica 3)..."
ssh_node1 "sudo gluster volume create $VOLUME_NAME \
  replica 3 transport tcp \
  $NODE1_IP:$BRICK_PATH \
  $NODE2_IP:$BRICK_PATH \
  $NODE3_IP:$BRICK_PATH \
  force"

echo "==> Starting volume..."
ssh_node1 "sudo gluster volume start $VOLUME_NAME"

ssh_node1 "sudo gluster volume info $VOLUME_NAME"

# ── 4. PostgreSQL-specific GlusterFS tuning ───────────────────────────────────
# Disable all caching layers to preserve PostgreSQL's fsync() semantics.
# Without these, GlusterFS may buffer writes and cause data corruption under
# crash recovery (fsync does not guarantee on-disk persistence with default settings).
echo "==> Applying PostgreSQL-safe tuning..."
ssh_node1 "sudo gluster volume set $VOLUME_NAME performance.cache-size 0"
ssh_node1 "sudo gluster volume set $VOLUME_NAME performance.write-behind off"
ssh_node1 "sudo gluster volume set $VOLUME_NAME performance.read-ahead off"
ssh_node1 "sudo gluster volume set $VOLUME_NAME performance.io-cache off"
ssh_node1 "sudo gluster volume set $VOLUME_NAME storage.batch-fsync-delay-usec 0"
echo "    PostgreSQL tuning applied."

# ── 5. Mount the volume on all nodes ─────────────────────────────────────────
echo "==> Mounting GlusterFS volume on all nodes..."

mount_on_node() {
  local node_ip=$1
  local mount_cmd="
    sudo mkdir -p $GLUSTER_MOUNT
    if ! grep -q '$VOLUME_NAME' /etc/fstab; then
      echo 'localhost:/$VOLUME_NAME $GLUSTER_MOUNT glusterfs defaults,_netdev,backupvolfile-server=$NODE2_IP 0 0' | sudo tee -a /etc/fstab
    fi
    sudo mount -t glusterfs localhost:/$VOLUME_NAME $GLUSTER_MOUNT || true
    df -h $GLUSTER_MOUNT
  "
  ssh $SSH_OPTS "${ADMIN_USER}@${node_ip}" "$mount_cmd"
}

mount_on_node "$NODE1_IP"
mount_on_node "$NODE2_IP"
mount_on_node "$NODE3_IP"

# ── 6. Create service sub-directories on node-1 ───────────────────────────────
# Only needs to run once — GlusterFS replicates to all bricks automatically.
echo "==> Creating service sub-directories..."
ssh_node1 "
  sudo mkdir -p $GLUSTER_MOUNT/postgres-data
  sudo mkdir -p $GLUSTER_MOUNT/redis-data
  sudo mkdir -p $GLUSTER_MOUNT/polaris-data
  sudo mkdir -p $GLUSTER_MOUNT/prometheus-data
  sudo mkdir -p $GLUSTER_MOUNT/grafana-data
  sudo chown -R 999:999 $GLUSTER_MOUNT/postgres-data  # postgres container UID
  sudo chown -R 999:999 $GLUSTER_MOUNT/redis-data     # redis container UID
  sudo chown -R 65534:65534 $GLUSTER_MOUNT/prometheus-data
  sudo chown -R 472:472 $GLUSTER_MOUNT/grafana-data
  sudo ls -la $GLUSTER_MOUNT/
"

# ── 7. Verify volume health ───────────────────────────────────────────────────
echo "==> Final volume status..."
ssh_node1 "sudo gluster volume status $VOLUME_NAME"

echo ""
echo "================================================================"
echo " GlusterFS bootstrap complete."
echo ""
echo " Volume:     $VOLUME_NAME"
echo " Mount:      $GLUSTER_MOUNT"
echo " Sub-dirs:   postgres-data/  redis-data/  polaris-data/  prometheus-data/  grafana-data/"
echo ""
echo " Next step: deploy the Docker Swarm stack"
echo "   ssh ${ADMIN_USER}@${NODE1_IP}"
echo "   docker stack deploy -c /opt/stacks/data-platform.yml data-platform"
echo "================================================================"
