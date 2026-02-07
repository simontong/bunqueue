# ============ Cloudflare Provider ============

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ============ GeoDNS Records ============

# Default record (fallback to EU)
resource "cloudflare_record" "api_default" {
  zone_id = var.cloudflare_zone_id
  name    = "api"
  value   = hcloud_load_balancer.regional["eu"].ipv4
  type    = "A"
  ttl     = 300
  proxied = true
}

# Geo-steering using Cloudflare Load Balancer
resource "cloudflare_load_balancer_pool" "eu" {
  account_id = var.cloudflare_account_id
  name       = "bunqueue-eu-pool"

  origins {
    name    = "eu-primary"
    address = hcloud_load_balancer.regional["eu"].ipv4
    enabled = true
  }

  latitude  = 50.1109
  longitude = 8.6821  # Frankfurt area

  notification_email = var.alert_email
}

resource "cloudflare_load_balancer_pool" "us" {
  account_id = var.cloudflare_account_id
  name       = "bunqueue-us-pool"

  origins {
    name    = "us-primary"
    address = hcloud_load_balancer.regional["us"].ipv4
    enabled = true
  }

  latitude  = 39.0438
  longitude = -77.4874  # Ashburn area

  notification_email = var.alert_email
}

resource "cloudflare_load_balancer_pool" "asia" {
  account_id = var.cloudflare_account_id
  name       = "bunqueue-asia-pool"

  origins {
    name    = "asia-primary"
    address = hcloud_load_balancer.regional["asia"].ipv4
    enabled = true
  }

  latitude  = 1.3521
  longitude = 103.8198  # Singapore

  notification_email = var.alert_email
}

# ============ Geo Load Balancer ============

resource "cloudflare_load_balancer" "api" {
  zone_id          = var.cloudflare_zone_id
  name             = "api.${var.domain}"
  fallback_pool_id = cloudflare_load_balancer_pool.eu.id
  default_pool_ids = [cloudflare_load_balancer_pool.eu.id]

  proxied     = true
  ttl         = 30
  steering_policy = "geo"

  # Geo routing rules
  region_pools {
    region   = "WEUR"  # Western Europe
    pool_ids = [cloudflare_load_balancer_pool.eu.id]
  }

  region_pools {
    region   = "EEUR"  # Eastern Europe
    pool_ids = [cloudflare_load_balancer_pool.eu.id]
  }

  region_pools {
    region   = "NAM"   # North America
    pool_ids = [cloudflare_load_balancer_pool.us.id]
  }

  region_pools {
    region   = "SAM"   # South America
    pool_ids = [cloudflare_load_balancer_pool.us.id]
  }

  region_pools {
    region   = "SEAS"  # Southeast Asia
    pool_ids = [cloudflare_load_balancer_pool.asia.id]
  }

  region_pools {
    region   = "NEAS"  # Northeast Asia
    pool_ids = [cloudflare_load_balancer_pool.asia.id]
  }

  region_pools {
    region   = "OC"    # Oceania
    pool_ids = [cloudflare_load_balancer_pool.asia.id]
  }

  # Pop-specific overrides (optional)
  pop_pools {
    pop      = "LAX"   # Los Angeles
    pool_ids = [cloudflare_load_balancer_pool.us.id]
  }

  pop_pools {
    pop      = "SIN"   # Singapore
    pool_ids = [cloudflare_load_balancer_pool.asia.id]
  }

  pop_pools {
    pop      = "FRA"   # Frankfurt
    pool_ids = [cloudflare_load_balancer_pool.eu.id]
  }
}

# ============ Health Checks ============

resource "cloudflare_load_balancer_monitor" "http" {
  account_id     = var.cloudflare_account_id
  type           = "http"
  expected_body  = ""
  expected_codes = "200"
  method         = "GET"
  timeout        = 5
  path           = "/health"
  interval       = 60
  retries        = 2
  description    = "bunqueue HTTP health check"

  header {
    header = "Host"
    values = ["api.${var.domain}"]
  }
}

# ============ Customer Subdomains ============

# Each customer gets: <customer-id>.api.bunqueue.io
resource "cloudflare_record" "customer" {
  for_each = var.customers

  zone_id = var.cloudflare_zone_id
  name    = "${each.key}.api"
  value   = "api.${var.domain}"
  type    = "CNAME"
  ttl     = 300
  proxied = true
}

# ============ SSL/TLS ============

resource "cloudflare_zone_settings_override" "ssl" {
  zone_id = var.cloudflare_zone_id

  settings {
    ssl                      = "strict"
    always_use_https         = "on"
    min_tls_version          = "1.2"
    automatic_https_rewrites = "on"
  }
}

# ============ Firewall Rules ============

resource "cloudflare_ruleset" "rate_limit" {
  zone_id     = var.cloudflare_zone_id
  name        = "bunqueue rate limiting"
  description = "Rate limit API requests"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules {
    action = "block"
    action_parameters {
      response {
        status_code = 429
        content     = "{\"error\": \"rate_limit_exceeded\"}"
        content_type = "application/json"
      }
    }
    ratelimit {
      characteristics = ["cf.colo.id", "ip.src"]
      period          = 60
      requests_per_period = 1000
      mitigation_timeout  = 60
    }
    expression  = "(http.request.uri.path contains \"/push\" or http.request.uri.path contains \"/pull\")"
    description = "Rate limit push/pull endpoints"
    enabled     = true
  }
}

# ============ Variables ============

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
}

variable "alert_email" {
  description = "Email for alerts"
  default     = "alerts@bunqueue.io"
}

# ============ Outputs ============

output "api_endpoint" {
  value = "https://api.${var.domain}"
}

output "customer_endpoints" {
  value = {
    for k, v in var.customers : k => "https://${k}.api.${var.domain}"
  }
}
