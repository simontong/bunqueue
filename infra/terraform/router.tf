# ============ Router Cluster ============

variable "router_count" {
  description = "Number of router instances (for HA)"
  default     = 3
}

resource "hcloud_server" "router" {
  count = var.router_count

  name        = "bunqueue-router-${count.index + 1}"
  server_type = "cx22"
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.default.id]

  labels = {
    service = "router"
    index   = count.index + 1
  }

  user_data = templatefile("${path.module}/templates/router-cloud-init.yml", {
    router_index = count.index + 1
    nodes_config = join(",", [
      for k, v in hcloud_server.bunqueue_regional :
      "${k}:${v.network[0].ip}:6789:6790:1:${var.customers_regional[k].region}"
    ])
    customers_config = join(",", [
      for k, v in var.customers_regional :
      "${k}:${k}"  # customer maps to their own node
    ])
  })

  network {
    network_id = hcloud_network.bunqueue.id
    ip         = "10.0.1.${100 + count.index}"
  }
}

# ============ Router Load Balancer ============

resource "hcloud_load_balancer" "router" {
  name               = "bunqueue-router-lb"
  load_balancer_type = "lb11"
  location           = var.location

  labels = {
    service = "router"
  }
}

resource "hcloud_load_balancer_network" "router" {
  load_balancer_id = hcloud_load_balancer.router.id
  network_id       = hcloud_network.bunqueue.id
  ip               = "10.0.1.50"
}

resource "hcloud_load_balancer_target" "router" {
  count = var.router_count

  type             = "server"
  load_balancer_id = hcloud_load_balancer.router.id
  server_id        = hcloud_server.router[count.index].id
  use_private_ip   = true
}

resource "hcloud_load_balancer_service" "router_http" {
  load_balancer_id = hcloud_load_balancer.router.id
  protocol         = "tcp"
  listen_port      = 6790
  destination_port = 6800

  health_check {
    protocol = "http"
    port     = 6800
    interval = 10
    timeout  = 5
    retries  = 3
    http {
      path         = "/health"
      status_codes = ["200"]
    }
  }
}

# ============ Router Firewall ============

resource "hcloud_firewall" "router" {
  name = "router-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6800"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "9091"
    source_ips = [hcloud_network.bunqueue.ip_range]
  }
}

resource "hcloud_firewall_attachment" "router" {
  count = var.router_count

  firewall_id = hcloud_firewall.router.id
  server_ids  = [hcloud_server.router[count.index].id]
}

# ============ Outputs ============

output "router_lb_ip" {
  value = hcloud_load_balancer.router.ipv4
}

output "router_ips" {
  value = [for s in hcloud_server.router : s.ipv4_address]
}
