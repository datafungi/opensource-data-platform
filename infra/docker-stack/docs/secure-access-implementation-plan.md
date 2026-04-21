# Secure Access Implementation Plan: Traefik + Cloudflare Access + Azure AD

Reference architecture: [secure-access-architecture.md](./secure-access-architecture.md)

This document provides the phased, step-by-step implementation plan for securing the 3-node Docker
Swarm cluster's web-facing services (Airflow, Grafana, Portainer) behind Traefik and Cloudflare
Access with Azure AD SSO. Phases are ordered so that no change is irreversible until the previous
phase is validated — specifically, the NSG is not hardened until Traefik is confirmed working.

---

## Prerequisites

The following must be true before starting Phase 1:

- [ ] Domain registered and nameservers delegated to Cloudflare (i.e., Cloudflare is the
      authoritative DNS for the domain used for the subdomains).
- [ ] Cloudflare account with Zero Trust enabled. The free tier supports up to 50 users and covers
      this use case entirely.
- [ ] Azure AD (Entra ID) tenant with Global Administrator or Application Administrator access
      to register an OIDC application.
- [ ] Terraform state accessible — either local state or a configured remote backend. Running
      `terraform init` and `terraform plan` must succeed before Phase 3.
- [ ] SSH access to node-1 (10.54.1.10) via the `allowed_ssh_cidr` NSG rule or Azure Bastion,
      to create the `/opt/traefik/acme.json` file and manage Docker secrets.
- [ ] All services currently healthy: `docker stack ps data-platform` shows no failed tasks.
      Make changes from a known-good baseline.

---

## Phase 1 — DNS and Cloudflare Access Setup

**Effort:** ~1–2 hours  
**Infrastructure changes:** None (Cloudflare dashboard only, no Terraform or Swarm changes)  
**Rollback:** Delete the DNS records and Access Applications if needed; no Azure state is modified.

### Step 1.1 — Confirm domain is in Cloudflare

Log into the Cloudflare dashboard and confirm the domain appears under your account with status
"Active". If the domain is not yet in Cloudflare, add it and update the domain registrar's
nameservers to the two Cloudflare nameservers shown in the dashboard. DNS propagation for
nameserver delegation can take up to 24–48 hours.

### Step 1.2 — Create DNS A records (proxied)

In Cloudflare DNS, create three A records pointing to node-1's public IP address. Set each record
to **Proxied** (orange cloud ON):

| Name | Type | Value | Proxy |
|------|------|-------|-------|
| `airflow` | A | `<node-1 public IP>` | Proxied |
| `grafana` | A | `<node-1 public IP>` | Proxied |
| `portainer` | A | `<node-1 public IP>` | Proxied |

Do NOT set any record to "DNS only" at any point — this exposes the origin IP.

### Step 1.3 — Register OIDC application in Azure AD

In the Azure portal (portal.azure.com), navigate to Azure Active Directory → App registrations →
New registration:

1. Name: `cloudflare-zero-trust` (or similar)
2. Supported account types: "Accounts in this organizational directory only"
3. Redirect URI: Leave blank for now (Cloudflare will provide this after the IdP is linked)
4. After creation, note the **Application (client) ID** and **Directory (tenant) ID**
5. Under Certificates & Secrets → New client secret — create a secret and note the value immediately
   (it is only shown once)
6. Under Authentication, add the redirect URI provided by Cloudflare Zero Trust after completing
   Step 1.4 (format: `https://TEAM_NAME.cloudflareaccess.com/cdn-cgi/access/callback`)

### Step 1.4 — Add Azure AD as Identity Provider in Cloudflare Zero Trust

In the Cloudflare Zero Trust dashboard (one.dash.cloudflare.com → Zero Trust):

1. Settings → Authentication → Add → Azure AD (OIDC)
2. Enter the Application (client) ID, Client Secret, and Directory (tenant) ID from Step 1.3
3. Save and copy the callback URL shown — add this URL back to the Azure AD app registration
   (Step 1.3, item 6)
4. Test the connection using the "Test" button in Cloudflare

### Step 1.5 — Create Azure AD group and assign users

In Azure AD:

1. Create a security group named `data-platform-admins`
2. Add the users who should have access to Airflow, Grafana, and Portainer
3. Note the group's Object ID — it will be referenced in the Cloudflare Access policy

In the Azure AD app registration (from Step 1.3):
- Under Token Configuration, add a groups claim so group membership is included in the OIDC token

### Step 1.6 — Create Cloudflare Access Applications

In Cloudflare Zero Trust → Access → Applications → Add Application → Self-hosted:

Create one application per subdomain (or a single wildcard application for `*.yourdomain.com`):

**Per-subdomain approach (recommended for fine-grained control):**

For each of `airflow.DOMAIN`, `grafana.DOMAIN`, `portainer.DOMAIN`:
1. Application name: e.g., `Airflow`
2. Application domain: `airflow.yourdomain.com`
3. Session duration: 8 hours (adjust to organisational policy)
4. Add a policy:
   - Policy name: `Allow data-platform-admins`
   - Action: Allow
   - Rules: Include → Azure AD group = `data-platform-admins`

### Step 1.7 — Generate Cloudflare API token (for ACME DNS-01 challenge)

If using the DNS-01 ACME challenge (recommended — avoids needing port 80 open for Let's Encrypt):

In Cloudflare dashboard → My Profile → API Tokens → Create Token:
- Template: "Edit zone DNS"
- Zone: select your domain
- Permissions: Zone:DNS:Edit

Copy the token value — it will be stored as a Docker secret in Phase 2.

### Step 1.8 — Note your Cloudflare Zero Trust team name

The team name appears in the Access login URL format: `https://TEAM_NAME.cloudflareaccess.com`.
Find it in Zero Trust → Settings → Custom Pages or in any Access Application's overview.
This value is needed for the Traefik JWT validation endpoint in Phase 2.

**Phase 1 Verification:**
Navigate to `https://airflow.yourdomain.com` in a browser. The Cloudflare Access login screen
(Azure AD redirect) should appear. The page will fail to load the backend — this is expected because
Traefik is not yet deployed. The important confirmation is that the Access login flow is triggered.

---

## Phase 2 — Traefik Deployment to Swarm

**Effort:** ~2–3 hours  
**Infrastructure changes:** Docker Swarm stack update (`data-platform.yml`)  
**Rollback:** Redeploy the stack without the Traefik service and without the label additions.
Services remain reachable on ports 8080/3000/9443 until Phase 3 — do NOT close those NSG rules
until this phase is fully validated.

### Step 2.1 — Create Docker secret for Cloudflare API token

SSH to node-1 and run:

```bash
echo "<CLOUDFLARE_API_TOKEN>" | docker secret create cf_dns_api_token -
```

Verify: `docker secret ls` should show `cf_dns_api_token`.

### Step 2.2 — Create acme.json on node-1

Let's Encrypt certificate storage requires a file with permissions 600:

```bash
sudo mkdir -p /opt/traefik
sudo touch /opt/traefik/acme.json
sudo chmod 600 /opt/traefik/acme.json
```

This file must exist on the manager node before Traefik starts. It will be empty initially;
Traefik writes certificate data to it after the first ACME challenge succeeds.

### Step 2.3 — Add Traefik service to data-platform.yml

Add the following service definition to `infra/docker-stack/compose/data-platform.yml`. Replace
`TEAM_NAME` with the value from Step 1.8 and `yourdomain.com` with the actual domain:

```yaml
services:
  traefik:
    image: traefik:v3
    command:
      - "--log.level=INFO"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--providers.swarm.endpoint=unix:///var/run/docker.sock"
      - "--providers.swarm.exposedbydefault=false"
      - "--providers.swarm.network=data-platform"
      - "--certificatesresolvers.letsencrypt.acme.dnschallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare"
      - "--certificatesresolvers.letsencrypt.acme.email=ops@yourdomain.com"
      - "--certificatesresolvers.letsencrypt.acme.storage=/opt/traefik/acme.json"
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: host
      - target: 443
        published: 443
        protocol: tcp
        mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/traefik/acme.json:/opt/traefik/acme.json
    environment:
      - CF_DNS_API_TOKEN_FILE=/run/secrets/cf_dns_api_token
    secrets:
      - cf_dns_api_token
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        # Global forwardAuth middleware — validates CF_Authorization JWT on every request
        - "traefik.http.middlewares.cf-access-auth.forwardauth.address=https://TEAM_NAME.cloudflareaccess.com/cdn-cgi/access/verify"
        - "traefik.http.middlewares.cf-access-auth.forwardauth.trustForwardHeader=true"
        # Dummy router required for Traefik to attach to a network in Swarm mode
        - "traefik.http.routers.traefik-noop.rule=Host(`traefik.internal`)"
        - "traefik.http.services.traefik-noop.loadbalancer.server.port=8080"
    networks:
      - data-platform

secrets:
  cf_dns_api_token:
    external: true
```

### Step 2.4 — Add Traefik labels to each application service

Add the following `deploy.labels` blocks to the three application services. These labels register
each service as a Traefik backend. Replace `yourdomain.com` with the actual domain.

**airflow-apiserver:**
```yaml
deploy:
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.airflow.rule=Host(`airflow.yourdomain.com`)"
    - "traefik.http.routers.airflow.entrypoints=websecure"
    - "traefik.http.routers.airflow.tls.certresolver=letsencrypt"
    - "traefik.http.routers.airflow.middlewares=cf-access-auth"
    - "traefik.http.services.airflow.loadbalancer.server.port=8080"
```

**grafana:**
```yaml
deploy:
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.grafana.rule=Host(`grafana.yourdomain.com`)"
    - "traefik.http.routers.grafana.entrypoints=websecure"
    - "traefik.http.routers.grafana.tls.certresolver=letsencrypt"
    - "traefik.http.routers.grafana.middlewares=cf-access-auth"
    - "traefik.http.services.grafana.loadbalancer.server.port=3000"
```

**portainer:**
```yaml
deploy:
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.portainer.rule=Host(`portainer.yourdomain.com`)"
    - "traefik.http.routers.portainer.entrypoints=websecure"
    - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
    - "traefik.http.routers.portainer.middlewares=cf-access-auth"
    # Route to port 9000 (HTTP) — TLS terminates at Traefik, not Portainer
    - "traefik.http.services.portainer.loadbalancer.server.port=9000"
```

### Step 2.5 — Deploy the updated stack

From the repository root on node-1 (or from a machine with Docker context pointing to the Swarm
manager):

```bash
docker stack deploy -c infra/docker-stack/compose/data-platform.yml data-platform
```

Watch Traefik start: `docker service logs -f data-platform_traefik`

Expected log lines:
- `Starting provider *docker.Provider`
- `Configuration loaded from Docker`
- Certificate request lines for each domain (ACME DNS-01 challenge)

### Step 2.6 — Verify Traefik router discovery

SSH to node-1 and check the Traefik API (accessible internally on port 8080 if the API is enabled,
or check logs):

```bash
# Check service is running
docker service ps data-platform_traefik

# View logs for router registration and certificate issuance
docker service logs data-platform_traefik 2>&1 | grep -E "router|certificate|error"
```

All three routers (airflow, grafana, portainer) should appear as registered with TLS resolvers.

### Step 2.7 — End-to-end test (before NSG hardening)

At this stage, both paths exist simultaneously: direct port access (8080/3000/9443 via NSG) and
the new Traefik path (443 via Cloudflare). Test the Traefik path:

1. Visit `https://airflow.yourdomain.com` — Cloudflare Access login should appear.
2. Authenticate with Azure AD credentials + MFA.
3. After successful login, the Airflow UI should load.
4. Repeat for `https://grafana.yourdomain.com` and `https://portainer.yourdomain.com`.

**Do not proceed to Phase 3 until all three services are accessible via the HTTPS subdomains.**

---

## Phase 3 — NSG Hardening

**Effort:** ~30 minutes  
**Infrastructure changes:** Terraform (`infra/docker-stack/terraform/azure/modules/networking/main.tf`)  
**Rollback:** Restore the original three rules in `main.tf` and run `terraform apply`.

### Step 3.1 — Update networking/main.tf

**Remove** the following three resource blocks from `networking/main.tf`:

```hcl
# DELETE THIS BLOCK
resource "azurerm_network_security_rule" "allow_airflow_ui" { ... }   # port 8080

# DELETE THIS BLOCK
resource "azurerm_network_security_rule" "allow_grafana" { ... }      # port 3000

# DELETE THIS BLOCK
resource "azurerm_network_security_rule" "allow_portainer" { ... }    # port 9443
```

**Add** the following two resource blocks in their place:

```hcl
resource "azurerm_network_security_rule" "allow_https" {
  name                        = "Allow-HTTPS"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefixes     = [
    # Cloudflare IPv4 ranges — update from https://www.cloudflare.com/ips-v4
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22",
    "103.31.4.0/22",  "141.101.64.0/18", "108.162.192.0/18",
    "190.93.240.0/20","188.114.96.0/20",  "197.234.240.0/22",
    "198.41.128.0/17","162.158.0.0/15",   "104.16.0.0/13",
    "104.24.0.0/14",  "172.64.0.0/13",    "131.0.72.0/22"
  ]
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "allow_http_acme" {
  name                        = "Allow-HTTP-ACME"
  priority                    = 105
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefixes     = [
    # Same Cloudflare IPv4 ranges as above
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22",
    "103.31.4.0/22",  "141.101.64.0/18", "108.162.192.0/18",
    "190.93.240.0/20","188.114.96.0/20",  "197.234.240.0/22",
    "198.41.128.0/17","162.158.0.0/15",   "104.16.0.0/13",
    "104.24.0.0/14",  "172.64.0.0/13",    "131.0.72.0/22"
  ]
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}
```

**Note:** The existing rules use `source_address_prefix` (singular string). The new rules use
`source_address_prefixes` (plural, list). Both are valid `azurerm_network_security_rule` attributes
but they are mutually exclusive — only one can be set per resource.

### Step 3.2 — Review Terraform plan

```bash
cd infra/docker-stack/terraform/azure
terraform plan
```

The plan output must show exactly:
- 3 resources to destroy (`allow_airflow_ui`, `allow_grafana`, `allow_portainer`)
- 2 resources to create (`allow_https`, `allow_http_acme`)

If the plan shows additional changes, investigate before applying.

### Step 3.3 — Apply

```bash
terraform apply
```

Review the confirmation prompt, type `yes` to apply.

### Step 3.4 — Verify NSG hardening

From a machine NOT in the Cloudflare IP range (i.e., your local machine or a test VM outside
Azure), attempt direct port access to node-1's public IP:

```bash
# These should all timeout or be refused after NSG hardening
curl --max-time 10 http://<NODE1_PUBLIC_IP>:8080
curl --max-time 10 http://<NODE1_PUBLIC_IP>:3000
curl -k --max-time 10 https://<NODE1_PUBLIC_IP>:9443
```

All three commands should time out. If any succeeds, the NSG rule was not applied correctly —
check Terraform state and the Azure portal NSG effective rules.

Confirm authenticated access still works: visit `https://airflow.yourdomain.com` and complete
the Cloudflare Access login flow.

---

## Phase 4 — Validation and Hardening

**Effort:** ~1 hour  
**Infrastructure changes:** Cloudflare dashboard (WAF settings); no Terraform or Swarm changes.  
**Rollback:** WAF rules can be disabled individually in the Cloudflare dashboard.

### Step 4.1 — Confirm direct port access is fully blocked

```bash
# Run from a non-Cloudflare IP (local machine is fine)
curl --max-time 10 http://<NODE1_PUBLIC_IP>:8080   # must timeout
curl --max-time 10 http://<NODE1_PUBLIC_IP>:3000   # must timeout
curl -k --max-time 10 https://<NODE1_PUBLIC_IP>:9443  # must timeout
```

### Step 4.2 — Confirm authenticated access works for all services

Log in via each subdomain with a valid `data-platform-admins` group member account:
- `https://airflow.yourdomain.com` → Airflow UI loads
- `https://grafana.yourdomain.com` → Grafana UI loads
- `https://portainer.yourdomain.com` → Portainer UI loads

### Step 4.3 — Confirm unauthenticated access is blocked

In a private/incognito browser window (no existing `CF_Authorization` cookie):
- Visit `https://airflow.yourdomain.com` → Should redirect to Azure AD login, NOT load Airflow

Test with a user NOT in the `data-platform-admins` group:
- Should be denied at the Cloudflare Access policy level (Access-blocked page shown)

### Step 4.4 — Enable Cloudflare WAF

In Cloudflare dashboard → your domain → Security → WAF:
1. Enable the OWASP Core Ruleset (managed rules)
2. Enable the Cloudflare Managed Ruleset
3. Set WAF sensitivity to Medium initially; adjust if false positives occur with Airflow or Portainer

In Cloudflare Zero Trust → Access → Applications → each application:
- Enable DDoS protection (included with proxied records at no additional cost)

### Step 4.5 — Review Cloudflare Access logs

In Cloudflare Zero Trust → Logs → Access:
- Confirm all recent requests show authenticated user identities
- Confirm no requests have passed through without authentication
- Review any blocked requests to confirm they are genuine denials (not misconfiguration)

### Step 4.6 — (Optional) Create service tokens for programmatic access

If CI/CD pipelines or monitoring tools need to access the Airflow REST API or Grafana API:

In Cloudflare Zero Trust → Access → Service Tokens → Create Service Token:
1. Name: e.g., `github-actions-airflow`
2. Copy the `CF-Access-Client-Id` and `CF-Access-Client-Secret` values
3. Store them as secrets in the CI/CD system
4. Add these headers to API requests:
   ```
   CF-Access-Client-Id: <client-id>
   CF-Access-Client-Secret: <client-secret>
   ```

Add a policy to each relevant Access Application that allows this service token in addition to
the Azure AD group policy.

---

## Change Summary Table

| Category | Files / Systems Changed | Phase |
|----------|------------------------|-------|
| Terraform | `infra/docker-stack/terraform/azure/modules/networking/main.tf` — remove 3 open rules, add 2 Cloudflare-scoped rules | 3 |
| Docker Swarm | `infra/docker-stack/compose/data-platform.yml` — add traefik service, add labels to airflow-apiserver, grafana, portainer | 2 |
| Cloudflare Dashboard | DNS records (3 proxied A records), Access Applications (3), Identity Provider (Azure AD OIDC config) | 1 |
| Azure AD / Entra ID | OIDC app registration for Cloudflare Zero Trust, `data-platform-admins` security group | 1 |
| Node filesystem | `/opt/traefik/acme.json` created on node-1 with permissions 600 | 2 |
| Docker secrets | `cf_dns_api_token` (external secret for Cloudflare DNS-01 challenge) | 2 |

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Traefik misconfiguration causes all services unreachable via HTTPS | Medium | High | Keep NSG open on ports 8080/3000/9443 until Phase 2 is fully validated (Step 2.7). Do not proceed to Phase 3 until end-to-end test passes. |
| ACME cert issuance fails due to Let's Encrypt rate limits or DNS propagation delay | Low | Medium | Use DNS-01 challenge (avoids port 80 requirement and propagation is faster). Test with Let's Encrypt staging endpoint first: add `--certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory` to Traefik command. |
| Cloudflare IP range changes cause NSG to block legitimate traffic | Low | High | Pin the IP list in a `locals` block in `networking/main.tf`. Review https://www.cloudflare.com/ips/ when running `terraform apply`. Consider a CI check that compares the pinned list against the live endpoint. |
| Azure AD OIDC misconfiguration blocks all users from logging in | Medium | High | Test the IdP connection using Cloudflare's "Test" button (Step 1.4) before creating Access Applications. Test with a single user account before assigning the group policy. |
| Portainer HTTPS backend incompatibility with Traefik (certificate chain errors) | Low | Low | Route Traefik to Portainer's HTTP listener on port 9000 rather than HTTPS on 9443. TLS terminates at Traefik; the Swarm overlay path is trusted. |
| Origin IP leakage via DNS (grey cloud set accidentally) | Low | High | Enforce a team convention: never set Cloudflare DNS records for these subdomains to "DNS only". Check orange cloud status after any DNS update. |
| acme.json file permissions too broad (readable by non-root) | Low | Medium | Always create with `chmod 600`. Traefik will refuse to start if permissions are too broad and will log a warning. |

---

## References

- Cloudflare IP ranges: https://www.cloudflare.com/ips/
- Traefik Docker Swarm provider docs: https://doc.traefik.io/traefik/providers/docker/#docker-swarm-mode
- Traefik ACME / Let's Encrypt docs: https://doc.traefik.io/traefik/https/acme/
- Traefik forwardAuth middleware: https://doc.traefik.io/traefik/middlewares/http/forwardauth/
- Cloudflare Access JWT validation: https://developers.cloudflare.com/cloudflare-one/identity/authorization-cookie/validating-json/
- Azure AD OIDC integration with Cloudflare Access: https://developers.cloudflare.com/cloudflare-one/identity/idp-integration/azuread/
- Cloudflare Access service tokens: https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/
- Azure NSG `source_address_prefixes` (plural): https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_rule
