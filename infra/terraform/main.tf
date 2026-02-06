terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

# ============ Variables ============

variable "hcloud_token" {
  description = "Hetzner Cloud API Token"
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for server access"
}

variable "location" {
  description = "Hetzner datacenter location"
  default     = "fsn1" # Falkenstein, Germany
}

# ============ SSH Key ============

resource "hcloud_ssh_key" "default" {
  name       = "bunqueue-key"
  public_key = var.ssh_public_key
}

# ============ Network ============

resource "hcloud_network" "bunqueue" {
  name     = "bunqueue-network"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "bunqueue" {
  network_id   = hcloud_network.bunqueue.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

# ============ Monitoring Server (Prometheus + Grafana) ============

resource "hcloud_server" "monitoring" {
  name        = "bunqueue-monitoring"
  server_type = "cx22"
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.default.id]

  labels = {
    service = "monitoring"
  }

  user_data = <<-EOF
    #cloud-config
    package_update: true
    packages:
      - docker.io
      - docker-compose

    runcmd:
      - systemctl enable docker
      - systemctl start docker
      - mkdir -p /opt/monitoring
      - cd /opt/monitoring
      - |
        cat > docker-compose.yml << 'COMPOSE'
        version: '3.8'
        services:
          prometheus:
            image: prom/prometheus:latest
            container_name: prometheus
            ports:
              - "9090:9090"
            volumes:
              - ./prometheus.yml:/etc/prometheus/prometheus.yml
              - prometheus_data:/prometheus
            command:
              - '--config.file=/etc/prometheus/prometheus.yml'
              - '--storage.tsdb.path=/prometheus'
              - '--storage.tsdb.retention.time=30d'
            restart: unless-stopped

          grafana:
            image: grafana/grafana:latest
            container_name: grafana
            ports:
              - "3000:3000"
            environment:
              - GF_SECURITY_ADMIN_PASSWORD=bunqueue-admin
              - GF_USERS_ALLOW_SIGN_UP=false
            volumes:
              - grafana_data:/var/lib/grafana
            restart: unless-stopped

          alertmanager:
            image: prom/alertmanager:latest
            container_name: alertmanager
            ports:
              - "9093:9093"
            volumes:
              - ./alertmanager.yml:/etc/alertmanager/alertmanager.yml
            restart: unless-stopped

        volumes:
          prometheus_data:
          grafana_data:
        COMPOSE
      - |
        cat > prometheus.yml << 'PROM'
        global:
          scrape_interval: 15s
          evaluation_interval: 15s

        alerting:
          alertmanagers:
            - static_configs:
                - targets: ['alertmanager:9093']

        scrape_configs:
          - job_name: 'prometheus'
            static_configs:
              - targets: ['localhost:9090']

          - job_name: 'bunqueue'
            static_configs:
              - targets: []
            relabel_configs:
              - source_labels: [__address__]
                target_label: instance
        PROM
      - |
        cat > alertmanager.yml << 'ALERT'
        global:
          resolve_timeout: 5m

        route:
          group_by: ['alertname', 'customer']
          group_wait: 10s
          group_interval: 10s
          repeat_interval: 1h
          receiver: 'default'

        receivers:
          - name: 'default'
        ALERT
      - docker-compose up -d
  EOF

  network {
    network_id = hcloud_network.bunqueue.id
    ip         = "10.0.1.10"
  }
}

# ============ Firewall ============

resource "hcloud_firewall" "monitoring" {
  name = "monitoring-firewall"

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "3000" # Grafana
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "9090" # Prometheus
    source_ips = ["10.0.0.0/16"]
  }
}

resource "hcloud_firewall" "bunqueue" {
  name = "bunqueue-firewall"

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "6789" # TCP API
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "6790" # HTTP API
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "9091" # Metrics
    source_ips = ["10.0.0.0/16"]
  }
}

resource "hcloud_firewall_attachment" "monitoring" {
  firewall_id = hcloud_firewall.monitoring.id
  server_ids  = [hcloud_server.monitoring.id]
}

# ============ Outputs ============

output "monitoring_ip" {
  value = hcloud_server.monitoring.ipv4_address
}

output "grafana_url" {
  value = "http://${hcloud_server.monitoring.ipv4_address}:3000"
}

output "network_id" {
  value = hcloud_network.bunqueue.id
}
