#cloud-config
# Rendered by Terraform templatefile() — do not edit directly.
# Variables: admin_username, is_primary, private_ip, primary_ip,
#            key_vault_name, backup_storage_account_name, backup_container_name

package_update: true
package_upgrade: false

packages:
  - xfsprogs
  - gnupg
  - curl
  - lsb-release
  - glusterfs-server

write_files:
  - path: /opt/node-setup.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail
      exec > /var/log/node-setup.log 2>&1
      echo "[node-setup] Starting on $(hostname) at $(date -u)"

      # ── 1. Format and mount GlusterFS data disk ───────────────────────────
      # Azure attaches the first data disk as LUN 0; the by-path symlink is
      # more stable than /dev/sdc which can shift if OS-disk numbering changes.
      BRICK_DEV=/dev/disk/azure/scsi1/lun0
      BRICK_MOUNT=/data/gluster/brick

      mkdir -p "$BRICK_MOUNT"

      if ! blkid "$BRICK_DEV" > /dev/null 2>&1; then
        echo "[node-setup] Formatting $BRICK_DEV as XFS"
        mkfs.xfs -f "$BRICK_DEV"
      fi

      DISK_UUID=$(blkid -s UUID -o value "$BRICK_DEV")
      if ! grep -q "$DISK_UUID" /etc/fstab; then
        echo "UUID=$DISK_UUID $BRICK_MOUNT xfs defaults,nofail 0 2" >> /etc/fstab
      fi
      mount -a
      echo "[node-setup] Brick disk mounted at $BRICK_MOUNT"

      # ── 2. Install Docker Engine ──────────────────────────────────────────
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc

      . /etc/os-release
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/ubuntu \
        $${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

      apt-get update -qq
      apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
      systemctl enable --now docker
      usermod -aG docker ${admin_username}
      echo "[node-setup] Docker Engine installed"

      # ── 3. Enable GlusterFS ───────────────────────────────────────────────
      systemctl enable --now glusterd
      echo "[node-setup] GlusterFS daemon enabled"

      # ── 4. Install Azure CLI ──────────────────────────────────────────────
      curl -sL https://aka.ms/InstallAzureCLIDeb | bash
      echo "[node-setup] Azure CLI installed"

      # ── 5. Wait for managed identity IMDS endpoint ────────────────────────
      # The IMDS token endpoint can take up to ~3 minutes to become ready
      # after first boot. Retry with backoff before attempting Key Vault ops.
      echo "[node-setup] Waiting for managed identity..."
      for i in $(seq 1 18); do
        if az login --identity --allow-no-subscriptions > /dev/null 2>&1; then
          echo "[node-setup] Managed identity login succeeded (attempt $i)"
          break
        fi
        echo "[node-setup] Identity not ready yet (attempt $i/18), retrying in 10s"
        sleep 10
      done

      # ── 6. Docker Swarm initialisation ────────────────────────────────────
      %{~ if is_primary }
      # node-1: initialise the Swarm and publish join tokens to Key Vault.
      echo "[node-setup] Initialising Docker Swarm on ${private_ip}"
      docker swarm init \
        --advertise-addr ${private_ip} \
        --listen-addr ${private_ip}:2377

      WORKER_TOKEN=$(docker swarm join-token worker -q)
      MANAGER_TOKEN=$(docker swarm join-token manager -q)

      az keyvault secret set \
        --vault-name "${key_vault_name}" \
        --name "swarm-worker-token" \
        --value "$WORKER_TOKEN" \
        --output none

      az keyvault secret set \
        --vault-name "${key_vault_name}" \
        --name "swarm-manager-token" \
        --value "$MANAGER_TOKEN" \
        --output none

      echo "[node-setup] Swarm initialised, tokens stored in Key Vault"

      # ── 7. Install Dokploy (node-1 only) ──────────────────────────────────
      # Dokploy provides a web-based deployment UI for managing Docker services.
      # Its default port (3000) conflicts with Grafana on the Swarm routing mesh,
      # so we remap the host binding to 3001 after the install script runs.
      echo "[node-setup] Installing Dokploy..."
      curl -sSL https://dokploy.com/install.sh | sh

      DOKPLOY_COMPOSE=/etc/dokploy/docker-compose.yml
      if [ -f "$DOKPLOY_COMPOSE" ]; then
        docker compose -f "$DOKPLOY_COMPOSE" down || true
        sed -i 's/"3000:3000"/"3001:3000"/g' "$DOKPLOY_COMPOSE"
        docker compose -f "$DOKPLOY_COMPOSE" up -d
        echo "[node-setup] Dokploy remapped to port 3001"
      else
        echo "[node-setup] WARNING: Dokploy compose file not found at $DOKPLOY_COMPOSE — port remap skipped"
      fi
      %{~ else }
      # node-2 / node-3: poll Key Vault until node-1 has stored the manager
      # join token, then join the Swarm. Maximum wait: 30 × 20s = 10 minutes.
      echo "[node-setup] Waiting for Swarm manager token from Key Vault..."
      JOINED=false
      for i in $(seq 1 30); do
        MANAGER_TOKEN=$(az keyvault secret show \
          --vault-name "${key_vault_name}" \
          --name "swarm-manager-token" \
          --query value -o tsv 2>/dev/null || echo "")

        if [ -n "$MANAGER_TOKEN" ]; then
          echo "[node-setup] Token retrieved, joining Swarm (attempt $i)"
          if docker swarm join \
            --token "$MANAGER_TOKEN" \
            ${primary_ip}:2377; then
            JOINED=true
            break
          fi
        fi

        echo "[node-setup] Not ready yet (attempt $i/30), retrying in 20s"
        sleep 20
      done

      if [ "$JOINED" != "true" ]; then
        echo "[node-setup] ERROR: Failed to join Swarm after 30 attempts"
        exit 1
      fi

      echo "[node-setup] Successfully joined Swarm"
      %{~ endif }

      # ── 7. Persist backup env vars for cron containers ────────────────────
      cat >> /etc/environment <<EOF
      BACKUP_STORAGE_ACCOUNT=${backup_storage_account_name}
      BACKUP_CONTAINER=${backup_container_name}
      EOF

      echo "[node-setup] Completed at $(date -u)"

runcmd:
  - [bash, /opt/node-setup.sh]
