# ============ Customer bunqueue instances ============

variable "customers" {
  description = "Map of customer configurations"
  type = map(object({
    plan        = string # "starter", "pro", "enterprise"
    auth_token  = string
  }))
  default = {}
}

locals {
  plan_specs = {
    starter = {
      server_type = "cx22"  # 2 vCPU, 4GB RAM
      disk_size   = 40
    }
    pro = {
      server_type = "cx32"  # 4 vCPU, 8GB RAM
      disk_size   = 80
    }
    enterprise = {
      server_type = "cx42"  # 8 vCPU, 16GB RAM
      disk_size   = 160
    }
  }
}

resource "hcloud_server" "bunqueue" {
  for_each = var.customers

  name        = "bunqueue-${each.key}"
  server_type = local.plan_specs[each.value.plan].server_type
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.default.id]

  labels = {
    service  = "bunqueue"
    customer = each.key
    plan     = each.value.plan
  }

  user_data = <<-EOF
    #cloud-config
    package_update: true
    packages:
      - curl
      - unzip

    runcmd:
      # Install Bun
      - curl -fsSL https://bun.sh/install | bash
      - ln -s /root/.bun/bin/bun /usr/local/bin/bun

      # Create bunqueue user
      - useradd -r -s /bin/false bunqueue
      - mkdir -p /opt/bunqueue /var/lib/bunqueue

      # Install bunqueue
      - cd /opt/bunqueue
      - /root/.bun/bin/bun add bunqueue

      # Create config
      - |
        cat > /opt/bunqueue/.env << 'ENV'
        TCP_PORT=6789
        HTTP_PORT=6790
        DATA_PATH=/var/lib/bunqueue/queue.db
        AUTH_TOKENS=${each.value.auth_token}
        METRICS_PORT=9091
        ENV

      # Create systemd service
      - |
        cat > /etc/systemd/system/bunqueue.service << 'SERVICE'
        [Unit]
        Description=bunqueue Job Queue Server
        After=network.target

        [Service]
        Type=simple
        User=root
        WorkingDirectory=/opt/bunqueue
        EnvironmentFile=/opt/bunqueue/.env
        ExecStart=/root/.bun/bin/bun run node_modules/bunqueue/dist/main.js
        Restart=always
        RestartSec=5

        [Install]
        WantedBy=multi-user.target
        SERVICE

      - systemctl daemon-reload
      - systemctl enable bunqueue
      - systemctl start bunqueue

      # Setup log rotation
      - |
        cat > /etc/logrotate.d/bunqueue << 'LOGROTATE'
        /var/log/bunqueue/*.log {
          daily
          rotate 7
          compress
          delaycompress
          missingok
          notifempty
        }
        LOGROTATE
  EOF

  network {
    network_id = hcloud_network.bunqueue.id
  }
}

resource "hcloud_firewall_attachment" "bunqueue" {
  for_each = var.customers

  firewall_id = hcloud_firewall.bunqueue.id
  server_ids  = [hcloud_server.bunqueue[each.key].id]
}

# ============ Update Prometheus targets ============

resource "null_resource" "update_prometheus" {
  for_each = var.customers

  triggers = {
    server_ip = hcloud_server.bunqueue[each.key].ipv4_address
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = hcloud_server.monitoring.ipv4_address
      user        = "root"
      private_key = file("~/.ssh/id_rsa")
    }

    inline = [
      "cd /opt/monitoring",
      "yq -i '.scrape_configs[] | select(.job_name == \"bunqueue\").static_configs[0].targets += [\"${hcloud_server.bunqueue[each.key].network[0].ip}:9091\"]' prometheus.yml",
      "docker-compose restart prometheus"
    ]
  }

  depends_on = [hcloud_server.bunqueue, hcloud_server.monitoring]
}

# ============ Customer Outputs ============

output "customer_endpoints" {
  value = {
    for k, v in hcloud_server.bunqueue : k => {
      tcp_endpoint  = "${v.ipv4_address}:6789"
      http_endpoint = "http://${v.ipv4_address}:6790"
      ip            = v.ipv4_address
    }
  }
}
