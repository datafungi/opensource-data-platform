ui = true

# File storage on GlusterFS — single node, no Raft peers needed.
storage "file" {
  path = "/openbao/data"
}

# TLS is disabled: Tailscale handles transport encryption at the network layer.
# All inbound traffic arrives over the tailnet (10.54.0.0/24 → 10.54.1.0/24);
# there is no direct public internet path to port 8200.
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

# Expose Prometheus metrics at /v1/sys/metrics?format=prometheus
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}

# Audit log to stdout — Docker/journald collects and rotates it.
# Changing this requires a config reload + bao audit enable rerun.
audit "file" "stdout" {
  options {
    file_path = "/dev/stdout"
  }
}
