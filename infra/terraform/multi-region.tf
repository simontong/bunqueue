# ============ Multi-Region Setup ============

variable "cloudflare_api_token" {
  description = "Cloudflare API Token"
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for your domain"
}

variable "domain" {
  description = "Base domain for bunqueue (e.g., bunqueue.io)"
  default     = "bunqueue.io"
}

# Regions configuration
variable "regions" {
  description = "Hetzner regions to deploy"
  default = {
    "eu" = {
      location    = "fsn1"      # Falkenstein, Germany
      continent   = "EU"
    }
    "us" = {
      location    = "ash"       # Ashburn, USA
      continent   = "NA"
    }
    "asia" = {
      location    = "sin"       # Singapore (if available, else use closest)
      continent   = "AS"
    }
  }
}

# ============ Regional Networks ============

resource "hcloud_network" "regional" {
  for_each = var.regions

  name     = "bunqueue-${each.key}"
  ip_range = "10.${index(keys(var.regions), each.key)}.0.0/16"
}

resource "hcloud_network_subnet" "regional" {
  for_each = var.regions

  network_id   = hcloud_network.regional[each.key].id
  type         = "cloud"
  network_zone = each.value.location == "ash" ? "us-east" : "eu-central"
  ip_range     = "10.${index(keys(var.regions), each.key)}.1.0/24"
}

# ============ Regional Monitoring ============

resource "hcloud_server" "monitoring_regional" {
  for_each = var.regions

  name        = "bunqueue-monitoring-${each.key}"
  server_type = "cx22"
  image       = "ubuntu-24.04"
  location    = each.value.location
  ssh_keys    = [hcloud_ssh_key.default.id]

  labels = {
    service = "monitoring"
    region  = each.key
  }

  user_data = templatefile("${path.module}/templates/monitoring-cloud-init.yml", {
    region = each.key
  })

  network {
    network_id = hcloud_network.regional[each.key].id
    ip         = "10.${index(keys(var.regions), each.key)}.1.10"
  }
}

# ============ Regional Load Balancers ============

resource "hcloud_load_balancer" "regional" {
  for_each = var.regions

  name               = "bunqueue-lb-${each.key}"
  load_balancer_type = "lb11"
  location           = each.value.location

  labels = {
    service = "bunqueue"
    region  = each.key
  }
}

resource "hcloud_load_balancer_network" "regional" {
  for_each = var.regions

  load_balancer_id = hcloud_load_balancer.regional[each.key].id
  network_id       = hcloud_network.regional[each.key].id
  ip               = "10.${index(keys(var.regions), each.key)}.1.5"
}

resource "hcloud_load_balancer_service" "http" {
  for_each = var.regions

  load_balancer_id = hcloud_load_balancer.regional[each.key].id
  protocol         = "tcp"
  listen_port      = 6790
  destination_port = 6790

  health_check {
    protocol = "http"
    port     = 6790
    interval = 10
    timeout  = 5
    retries  = 3
    http {
      path         = "/health"
      status_codes = ["200"]
    }
  }
}

resource "hcloud_load_balancer_service" "tcp" {
  for_each = var.regions

  load_balancer_id = hcloud_load_balancer.regional[each.key].id
  protocol         = "tcp"
  listen_port      = 6789
  destination_port = 6789

  health_check {
    protocol = "tcp"
    port     = 6789
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

# ============ Outputs ============

output "regional_lb_ips" {
  value = {
    for k, v in hcloud_load_balancer.regional : k => v.ipv4
  }
}
