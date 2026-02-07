# ============ Regional Customer Instances ============

variable "customers_regional" {
  description = "Customers with their preferred region"
  type = map(object({
    plan       = string
    auth_token = string
    region     = string  # "eu", "us", "asia"
  }))
  default = {}
}

# ============ Customer Servers ============

resource "hcloud_server" "bunqueue_regional" {
  for_each = var.customers_regional

  name        = "bunqueue-${each.key}"
  server_type = local.plan_specs[each.value.plan].server_type
  image       = "ubuntu-24.04"
  location    = var.regions[each.value.region].location
  ssh_keys    = [hcloud_ssh_key.default.id]

  labels = {
    service  = "bunqueue"
    customer = each.key
    plan     = each.value.plan
    region   = each.value.region
  }

  user_data = templatefile("${path.module}/templates/bunqueue-cloud-init.yml", {
    customer_id = each.key
    auth_token  = each.value.auth_token
    region      = each.value.region
  })

  network {
    network_id = hcloud_network.regional[each.value.region].id
  }
}

# ============ Add to Load Balancer ============

resource "hcloud_load_balancer_target" "bunqueue" {
  for_each = var.customers_regional

  type             = "server"
  load_balancer_id = hcloud_load_balancer.regional[each.value.region].id
  server_id        = hcloud_server.bunqueue_regional[each.key].id
  use_private_ip   = true
}

# ============ Register with Prometheus ============

resource "null_resource" "register_prometheus" {
  for_each = var.customers_regional

  triggers = {
    server_ip = hcloud_server.bunqueue_regional[each.key].network[0].ip
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = hcloud_server.monitoring_regional[each.value.region].ipv4_address
      user        = "root"
      private_key = file(var.ssh_private_key_path)
    }

    inline = [
      "mkdir -p /etc/prometheus/targets",
      <<-EOT
      cat > /etc/prometheus/targets/${each.key}.json << 'JSON'
      [
        {
          "targets": ["${hcloud_server.bunqueue_regional[each.key].network[0].ip}:9091"],
          "labels": {
            "customer": "${each.key}",
            "plan": "${each.value.plan}",
            "region": "${each.value.region}"
          }
        }
      ]
      JSON
      EOT
    ]
  }

  depends_on = [hcloud_server.bunqueue_regional, hcloud_server.monitoring_regional]
}

# ============ Customer Firewall ============

resource "hcloud_firewall" "bunqueue_regional" {
  for_each = toset(keys(var.regions))

  name = "bunqueue-fw-${each.key}"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6789"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6790"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "9091"
    source_ips = [hcloud_network.regional[each.key].ip_range]
  }
}

resource "hcloud_firewall_attachment" "bunqueue_regional" {
  for_each = var.customers_regional

  firewall_id = hcloud_firewall.bunqueue_regional[each.value.region].id
  server_ids  = [hcloud_server.bunqueue_regional[each.key].id]
}

# ============ Variables ============

variable "ssh_private_key_path" {
  description = "Path to SSH private key"
  default     = "~/.ssh/id_rsa"
}

# ============ Outputs ============

output "customer_regional_endpoints" {
  value = {
    for k, v in hcloud_server.bunqueue_regional : k => {
      region        = var.customers_regional[k].region
      ip            = v.ipv4_address
      private_ip    = v.network[0].ip
      endpoint      = "https://${k}.api.${var.domain}"
    }
  }
}
