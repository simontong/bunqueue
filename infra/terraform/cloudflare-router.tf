# ============ Cloudflare with Router Layer ============

# All traffic goes to Router LB, router handles node selection

resource "cloudflare_record" "api_router" {
  zone_id = var.cloudflare_zone_id
  name    = "api"
  value   = hcloud_load_balancer.router.ipv4
  type    = "A"
  ttl     = 300
  proxied = true
}

# Regional routers for geo-routing
resource "cloudflare_load_balancer_pool" "router_eu" {
  account_id = var.cloudflare_account_id
  name       = "bunqueue-router-eu"

  origins {
    name    = "router-eu"
    address = hcloud_load_balancer.router.ipv4  # EU router LB
    enabled = true
  }

  latitude  = 50.1109
  longitude = 8.6821

  notification_email = var.alert_email
}

# If you have regional router clusters:
# resource "cloudflare_load_balancer_pool" "router_us" { ... }
# resource "cloudflare_load_balancer_pool" "router_asia" { ... }

resource "cloudflare_load_balancer" "api_router" {
  zone_id          = var.cloudflare_zone_id
  name             = "api.${var.domain}"
  fallback_pool_id = cloudflare_load_balancer_pool.router_eu.id
  default_pool_ids = [cloudflare_load_balancer_pool.router_eu.id]

  proxied         = true
  ttl             = 30
  steering_policy = "geo"

  # Add regional pools when you have multi-region routers
  region_pools {
    region   = "WEUR"
    pool_ids = [cloudflare_load_balancer_pool.router_eu.id]
  }

  region_pools {
    region   = "EEUR"
    pool_ids = [cloudflare_load_balancer_pool.router_eu.id]
  }

  # Uncomment when you add US/Asia router clusters
  # region_pools {
  #   region   = "NAM"
  #   pool_ids = [cloudflare_load_balancer_pool.router_us.id]
  # }
}

# ============ Rate Limiting at Router Level ============

resource "cloudflare_ruleset" "router_rate_limit" {
  zone_id     = var.cloudflare_zone_id
  name        = "Router rate limiting"
  description = "Rate limit at router entry point"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules {
    action = "block"
    action_parameters {
      response {
        status_code  = 429
        content      = "{\"error\": \"rate_limit_exceeded\", \"retry_after\": 60}"
        content_type = "application/json"
      }
    }
    ratelimit {
      characteristics     = ["cf.colo.id", "http.request.headers[\"x-customer-id\"]"]
      period              = 60
      requests_per_period = 10000  # Per customer per minute
      mitigation_timeout  = 60
    }
    expression  = "true"
    description = "Global rate limit per customer"
    enabled     = true
  }
}
