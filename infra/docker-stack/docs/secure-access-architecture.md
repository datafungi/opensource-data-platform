# Secure Access Architecture: Traefik + Cloudflare Access + Azure AD

## 1. Overview

The current 3-node Docker Swarm cluster exposes Airflow, Grafana, and Portainer directly on ports
8080, 3000, and 9443 to the Internet with no authentication layer at the network perimeter. This
architecture collapses those three open ports into a single TLS-terminated entry point on port 443,
fronted by Cloudflare's reverse proxy and Zero Trust Access product. All inbound traffic is
intercepted at the Cloudflare edge before reaching the origin VM: unauthenticated requests are
redirected to Azure AD (Entra ID) for SSO login, and only requests carrying a valid Cloudflare
Access JWT are forwarded to node-1. Traefik, running as a Docker Swarm service, receives those
forwarded requests, re-validates the JWT, and routes traffic to the appropriate backend over the
internal Swarm overlay network. The result is zero direct-to-VM port exposure for web-facing
services and identity-aware access control enforced at two independent layers.

---

## 2. Architecture Diagram

```
                        ┌─────────────────────────────────────────────────┐
                        │              CLOUDFLARE EDGE                    │
                        │                                                 │
   Browser              │  ┌──────────────┐    ┌─────────────────────┐   │
   ──────►  DNS proxy   │  │  Cloudflare  │    │  Cloudflare Access  │   │
           (orange      │  │  WAF / DDoS  │───►│  JWT validation +   │   │
           cloud ON)    │  │  protection  │    │  Azure AD SSO       │   │
                        │  └──────────────┘    └─────────┬───────────┘   │
                        └────────────────────────────────┼───────────────┘
                                                         │ CF_Authorization JWT
                                                         ▼
                        ┌─────────────────────────────────────────────────┐
                        │  Azure Network Security Group (nodes-nsg)       │
                        │  Allow-HTTPS :443  source: Cloudflare IP ranges │
                        │  Allow-HTTP  :80   source: Cloudflare IP ranges │
                        └─────────────────────────────────────────────────┘
                                                         │
                                                         ▼
                        ┌─────────────────────────────────────────────────┐
                        │  node-1  (10.54.1.10, Public IP)                │
                        │                                                 │
                        │  ┌───────────────────────────────────────────┐  │
                        │  │  Traefik v3 (Swarm service)               │  │
                        │  │  - TLS termination (Let's Encrypt ACME)   │  │
                        │  │  - forwardAuth middleware (CF JWT check)   │  │
                        │  │  - Swarm label-based service discovery     │  │
                        │  └──────┬──────────────────────┬─────────────┘  │
                        └─────────┼──────────────────────┼────────────────┘
                                  │  Swarm overlay network (data-platform)
                    ┌─────────────┼──────────────────────┼──────────────┐
                    │             │                        │              │
                    ▼             ▼                        ▼              │
          airflow-apiserver   grafana                portainer            │
          :8080               :3000                  :9443 (HTTPS)        │
                                                     :9000 (HTTP)         │
                    └────────────────────────────────────────────────────┘

Request path: Browser → CF Edge (WAF + Access auth) → NSG → node-1:443
              → Traefik (TLS termination + JWT re-validation)
              → Swarm overlay → backend service
```

---

## 3. Component Overview

### 3a. Traefik v3 (Swarm Service)

Traefik is deployed as a Docker Swarm service pinned to the manager node. It is the sole TLS
termination point on the cluster and the internal request router.

- **Listening ports:** 80 (HTTP, used for ACME HTTP-01 challenge or Cloudflare redirect) and
  443 (HTTPS, primary entry point). Both are published via the Swarm routing mesh.
- **TLS certificates:** Obtained automatically via Let's Encrypt using either the HTTP-01 challenge
  (port 80 must accept Cloudflare IP ranges) or DNS-01 challenge via Cloudflare API token (no
  port 80 requirement). Certificates are stored in `/opt/traefik/acme.json` on node-1.
- **Service discovery:** Traefik reads Docker Swarm service labels to automatically register
  backend routers. No static backend configuration is required; adding labels to a service is
  sufficient to expose it through Traefik.
- **JWT validation:** A `forwardAuth` middleware is configured to validate the `CF_Authorization`
  cookie on every inbound request against Cloudflare's public key endpoint
  (`https://TEAM_NAME.cloudflareaccess.com/cdn-cgi/access/certs`). Requests without a valid JWT
  are rejected with HTTP 401 before reaching the backend.
- **Routes:**
  - `airflow.DOMAIN` → `airflow-apiserver:8080`
  - `grafana.DOMAIN` → `grafana:3000`
  - `portainer.DOMAIN` → `portainer:9000` (HTTP internally; TLS terminates at Traefik)

### 3b. Cloudflare Access (Zero Trust)

Cloudflare Access sits in front of the origin and enforces identity-aware access control at the
Cloudflare edge before any traffic reaches the VM.

- **DNS proxying:** All subdomain DNS records (airflow, grafana, portainer) are set to "Proxied"
  (orange cloud ON). This hides the node-1 public IP from DNS responses entirely.
- **Access Applications:** One Access Application is created per subdomain (or a single wildcard
  application for `*.DOMAIN`). Each application defines the allowed audience.
- **Access Policy:** Action = Allow when Identity Provider = Azure AD AND user is a member of the
  `data-platform-admins` Azure AD group. All other requests are blocked at the Cloudflare edge.
- **JWT issuance:** After successful Azure AD authentication, Cloudflare Access issues a
  short-lived JWT (1-hour default expiry) and sets it as a `CF_Authorization` cookie. This JWT
  is included in all subsequent requests forwarded to the origin.
- **JWT public key endpoint:** Traefik retrieves Cloudflare's public signing key from
  `https://TEAM_NAME.cloudflareaccess.com/cdn-cgi/access/certs` to validate JWTs locally without
  a round-trip to Cloudflare on each request.

### 3c. Azure AD (Entra ID) as Identity Provider

Azure AD acts as the authoritative identity provider, handling user authentication and group
membership enforcement.

- **OIDC registration:** An OIDC application is registered in Azure AD (Entra ID) and linked to
  Cloudflare Zero Trust as an Identity Provider. The client ID and client secret from the Entra ID
  app registration are entered into the Cloudflare Zero Trust dashboard.
- **Group-based access:** Users must be members of the `data-platform-admins` group in Azure AD
  to satisfy the Cloudflare Access policy. Group membership is evaluated at login time.
- **MFA enforcement:** Multi-factor authentication is enforced via an Azure AD Conditional Access
  policy applied to the OIDC application. This is independent of Cloudflare Access and adds a
  second enforcement layer.

---

## 4. Request Data Flow

1. User navigates to `airflow.yourdomain.com` in a browser.
2. DNS resolves the `airflow` subdomain to a Cloudflare proxy IP address. The origin node-1 IP is
   not returned in the DNS response.
3. Cloudflare Access intercepts the request. No valid `CF_Authorization` cookie is present, so the
   user is redirected to the Azure AD login page.
4. The user authenticates with Azure AD credentials and completes MFA (enforced by Conditional
   Access). Azure AD returns an OIDC token to Cloudflare Access.
5. Cloudflare Access validates the OIDC token, checks group membership (`data-platform-admins`),
   issues a signed JWT, sets the `CF_Authorization` cookie, and forwards the original request to
   the origin (node-1 public IP on port 443).
6. The request arrives at node-1:443. The Azure NSG allows this traffic because the source IP is
   within the Cloudflare IP ranges (rules Allow-HTTPS and Allow-HTTP). Requests from any other
   source IP are dropped by the NSG.
7. Traefik receives the HTTPS request, terminates TLS, and validates the `CF_Authorization` JWT
   using the `forwardAuth` middleware against the Cloudflare Access public key endpoint.
8. If the JWT is valid and unexpired, Traefik matches the `Host` header to the appropriate router
   rule and forwards the request to the backend service on the Swarm overlay network (e.g.,
   `airflow-apiserver:8080`).
9. The backend service processes the request and returns a response. The response travels back
   through Traefik → Cloudflare edge → browser. The user sees the Airflow UI.

---

## 5. NSG Changes Required

The following changes must be applied to the Azure NSG resource `azurerm_network_security_group.nodes`
in `infra/docker-stack/terraform/azure/modules/networking/main.tf`:

| Rule Name | Action | Port | Source | Priority | Reason |
|-----------|--------|------|--------|----------|--------|
| Allow-Airflow-UI | REMOVE | 8080 | Internet | 100 | Port moved behind Traefik; direct access no longer needed |
| Allow-Grafana | REMOVE | 3000 | Internet | 110 | Port moved behind Traefik; direct access no longer needed |
| Allow-Portainer | REMOVE | 9443 | Internet | 115 | Port moved behind Traefik; direct access no longer needed |
| Allow-HTTPS | ADD | 443 | Cloudflare IP ranges | 100 | Traefik TLS entry point; restricted to Cloudflare egress IPs |
| Allow-HTTP-ACME | ADD | 80 | Cloudflare IP ranges | 105 | ACME HTTP-01 challenge or Cloudflare HTTP→HTTPS redirect |

**Cloudflare IP ranges:**
- IPv4: https://www.cloudflare.com/ips-v4 (15 prefixes as of 2025)
- IPv6: https://www.cloudflare.com/ips-v6

The Terraform `azurerm_network_security_rule` resource supports `source_address_prefixes` (plural,
accepts a list of strings) which allows specifying all Cloudflare CIDR blocks in a single rule.
The `source_address_prefix` (singular) attribute used in the current rules only accepts a single
value; it must be replaced with `source_address_prefixes` when using a list.

---

## 6. DNS Requirements

All DNS records must be managed through Cloudflare and set to **Proxied** (orange cloud ON).
Setting a record to "DNS only" (grey cloud) exposes the origin IP address in DNS responses,
defeating the purpose of the Cloudflare proxy layer.

| Subdomain | Record Type | Value | Proxy Status |
|-----------|-------------|-------|--------------|
| `airflow.DOMAIN` | A | node-1 public IP | Proxied (orange cloud ON) |
| `grafana.DOMAIN` | A | node-1 public IP | Proxied (orange cloud ON) |
| `portainer.DOMAIN` | A | node-1 public IP | Proxied (orange cloud ON) |
| `*.DOMAIN` (optional) | A | node-1 public IP | Proxied (orange cloud ON) |

**Important:** Never toggle a DNS record to "DNS only" for debugging or testing — this immediately
leaks the origin IP. If testing is needed, use an internal host entry or the Azure Bastion SSH
tunnel instead.

---

## 7. Traefik Configuration Sketch

The following shows the essential Swarm stack additions. This is not a complete file — only the
sections that need to be added or modified.

```yaml
services:
  traefik:
    image: traefik:v3
    command:
      # Entry points
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      # Docker Swarm provider
      - "--providers.swarm.endpoint=unix:///var/run/docker.sock"
      - "--providers.swarm.exposedbydefault=false"
      # Let's Encrypt (DNS-01 via Cloudflare — swap for http challenge if preferred)
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
      placement:
        constraints:
          - node.role == manager
      labels:
        # Global forwardAuth middleware for Cloudflare Access JWT validation
        - "traefik.http.middlewares.cf-access-auth.forwardauth.address=https://TEAM_NAME.cloudflareaccess.com/cdn-cgi/access/verify"
        - "traefik.http.middlewares.cf-access-auth.forwardauth.trustForwardHeader=true"
    networks:
      - data-platform

  # Example: labels to add to airflow-apiserver service
  airflow-apiserver:
    # ... existing config ...
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.airflow.rule=Host(`airflow.yourdomain.com`)"
        - "traefik.http.routers.airflow.entrypoints=websecure"
        - "traefik.http.routers.airflow.tls.certresolver=letsencrypt"
        - "traefik.http.routers.airflow.middlewares=cf-access-auth"
        - "traefik.http.services.airflow.loadbalancer.server.port=8080"

  # Example: labels for Portainer (route to HTTP port 9000 internally)
  portainer:
    # ... existing config ...
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.portainer.rule=Host(`portainer.yourdomain.com`)"
        - "traefik.http.routers.portainer.entrypoints=websecure"
        - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
        - "traefik.http.routers.portainer.middlewares=cf-access-auth"
        # Route to port 9000 (HTTP) internally; TLS terminates at Traefik
        - "traefik.http.services.portainer.loadbalancer.server.port=9000"

secrets:
  cf_dns_api_token:
    external: true
```

**Notes:**
- The `forwardAuth` middleware points to Cloudflare's JWT verification endpoint. Traefik will send
  the `CF_Authorization` header to this endpoint and only forward the request to the backend if
  Cloudflare returns HTTP 200.
- Port mode `host` on Traefik published ports ensures the source IP is preserved (needed for
  Cloudflare IP range validation at the application layer if desired).
- Portainer is routed to port 9000 (HTTP) internally so that Traefik does not need to manage a
  second TLS connection to the backend.

---

## 8. Cloudflare Access Policy Sketch

The following describes the logical configuration in the Cloudflare Zero Trust dashboard. This is
not a UI screenshot guide — it describes the policy structure a developer must configure.

```
Cloudflare Zero Trust Dashboard
└── Settings → Authentication → Identity Providers
    └── Add Provider: Azure AD (OIDC)
        ├── Client ID: <from Entra ID app registration>
        ├── Client Secret: <from Entra ID app registration>
        └── Tenant ID / Directory ID: <from Azure AD>

└── Access → Applications → Add Application (Self-hosted)
    ├── Application name: Airflow
    ├── Application domain: airflow.yourdomain.com
    ├── Session duration: 8h (or as appropriate)
    └── Policies
        └── Policy name: Allow data-platform-admins
            ├── Action: Allow
            └── Rules:
                ├── Include: Identity Provider = Azure AD
                └── Require: Azure Groups = data-platform-admins

    (Repeat for grafana.yourdomain.com and portainer.yourdomain.com)

JWT Validation:
└── Cloudflare Access public key endpoint (used by Traefik forwardAuth):
    https://TEAM_NAME.cloudflareaccess.com/cdn-cgi/access/certs

    Where TEAM_NAME is your Cloudflare Zero Trust organization name
    (visible in Zero Trust → Settings → Custom Pages or the Access login URL)

Service Tokens (for programmatic/API access, e.g. CI/CD):
└── Access → Service Tokens → Create Service Token
    ├── Name: traefik-validator (or airflow-api-ci)
    └── Returns: CF-Access-Client-Id and CF-Access-Client-Secret headers
        (Use these headers instead of CF_Authorization cookie for API calls)
```

---

## 9. Security Considerations

**NSG source restriction:** The NSG rules must use `source_address_prefixes` scoped to Cloudflare's
published IP ranges, not `source_address_prefix = "Internet"`. If the source is left as "Internet",
an attacker who discovers the node-1 public IP can bypass Cloudflare Access entirely by sending
requests directly to port 443. Restricting to Cloudflare IPs closes this origin bypass vector.
See Cloudflare's IP ranges at https://www.cloudflare.com/ips/ and update the Terraform variable
when Cloudflare publishes range changes.

**SSH access:** The `allow_ssh` NSG rule is already restricted to a specific CIDR (`var.allowed_ssh_cidr`).
Do not broaden this rule. Prefer Azure Bastion (`var.enable_bastion = true`) over direct SSH when
the allowed CIDR is impractical to maintain.

**Cloudflare WAF:** Enable the Cloudflare WAF (OWASP managed ruleset + DDoS protection) on each
Access Application. This adds a threat-filtering layer before authentication even begins.

**JWT expiry and re-validation:** Cloudflare Access JWTs expire in 1 hour by default. Traefik's
`forwardAuth` middleware re-validates the JWT on every request, so expired tokens are immediately
rejected without requiring explicit session management in the backend services.

**Portainer backend TLS:** Portainer listens on HTTPS/9443 internally by default. Traefik should
route to Portainer's HTTP listener on port 9000 rather than the HTTPS port on 9443. This avoids
a second TLS layer where Traefik would need to skip certificate verification for an internal
self-signed cert. TLS is fully handled by Traefik at the edge; the internal path is trusted by
the Swarm overlay network.

**Cloudflare Access audit logs:** Every authenticated request through Cloudflare Access is logged
with the user identity, timestamp, and action. These logs are accessible in the Cloudflare Zero
Trust dashboard under Logs → Access. No additional logging infrastructure is required for basic
audit trail purposes.

**IP range staleness:** Cloudflare publishes updates to their IP ranges infrequently but does
change them. The Terraform Cloudflare IP list should be pinned in a `locals` block or variable and
reviewed against https://www.cloudflare.com/ips/ when performing any Terraform apply. Consider
automating this check via a CI job that compares the pinned list against the live Cloudflare
endpoint.
