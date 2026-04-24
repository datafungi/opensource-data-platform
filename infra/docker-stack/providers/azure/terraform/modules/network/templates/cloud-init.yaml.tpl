#cloud-config
# Rendered by Terraform templatefile() — do not edit directly.
# Variables: key_vault_name, hostname

package_update: true

packages:
  - curl
  - jq

write_files:
  - path: /etc/sysctl.d/99-tailscale.conf
    content: |
      net.ipv4.ip_forward = 1
      net.ipv6.conf.all.forwarding = 1

  - path: /opt/tailscale-setup.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail
      exec > /var/log/tailscale-setup.log 2>&1
      echo "[tailscale-setup] Starting on $(hostname) at $(date -u)"

      # ── 1. Apply kernel IP forwarding settings ────────────────────────────
      # Required at the OS level in addition to Azure NIC ip_forwarding_enabled.
      sysctl -p /etc/sysctl.d/99-tailscale.conf
      echo "[tailscale-setup] IP forwarding enabled"

      # ── 2. Install Tailscale ──────────────────────────────────────────────
      curl -fsSL https://tailscale.com/install.sh | sh
      systemctl enable --now tailscaled
      echo "[tailscale-setup] Tailscale installed and daemon started"

      # ── 3. Retrieve auth key from Key Vault via managed identity ──────────
      # IMDS token endpoint can take up to ~3 minutes on first boot.
      echo "[tailscale-setup] Waiting for managed identity..."
      for i in $(seq 1 18); do
        TOKEN=$(curl -sf -H "Metadata: true" \
          "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" \
          | jq -r .access_token 2>/dev/null || echo "")
        if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
          echo "[tailscale-setup] Identity token acquired (attempt $i)"
          break
        fi
        echo "[tailscale-setup] Identity not ready (attempt $i/18), retrying in 10s"
        sleep 10
      done

      AUTH_KEY=$(curl -sf \
        -H "Authorization: Bearer $TOKEN" \
        "https://${key_vault_name}.vault.azure.net/secrets/tailscale-auth-key?api-version=7.4" \
        | jq -r .value)

      if [ -z "$AUTH_KEY" ] || [ "$AUTH_KEY" = "null" ]; then
        echo "[tailscale-setup] ERROR: Failed to retrieve auth key from Key Vault"
        exit 1
      fi
      echo "[tailscale-setup] Auth key retrieved"

      # ── 4. Bring up Tailscale as subnet router and exit node ──────────────
      # --advertise-routes: expose the entire VNet CIDR to the tailnet so any
      #   tailnet device can reach cluster nodes without Tailscale installed on them.
      # --advertise-exit-node: route all internet traffic through this VM,
      #   turning it into a self-hosted VPN exit point.
      # --accept-dns=false: keep the VM's own DNS resolver unchanged.
      tailscale up \
        --auth-key="$AUTH_KEY" \
        --advertise-routes=10.54.0.0/16 \
        --advertise-exit-node \
        --accept-dns=false \
        --hostname="${hostname}"

      echo "[tailscale-setup] Subnet router and exit node active"
      echo "[tailscale-setup] ACTION REQUIRED: approve routes and exit node at https://login.tailscale.com/admin/machines"
      echo "[tailscale-setup] Completed at $(date -u)"

runcmd:
  - [bash, /opt/tailscale-setup.sh]
