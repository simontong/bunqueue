# bunqueue Cloud Infrastructure

Terraform configuration for deploying bunqueue SaaS on Hetzner Cloud with Cloudflare GeoDNS.

## Architectures

### Single Region (Simple)

```
┌─────────────────────────────────────────────────────────────┐
│                    Hetzner Cloud                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                  │
│  │Customer A│  │Customer B│  │Customer C│                  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                  │
│       └─────────────┼─────────────┘                         │
│                     ▼                                       │
│            ┌─────────────────┐                              │
│            │   Prometheus    │                              │
│            │   + Grafana     │                              │
│            └─────────────────┘                              │
└─────────────────────────────────────────────────────────────┘
```

### Multi-Region with GeoDNS (Production)

```
                        ┌─────────────────────┐
                        │     Cloudflare      │
                        │      GeoDNS         │
                        │  api.bunqueue.io    │
                        └──────────┬──────────┘
                                   │
           ┌───────────────────────┼───────────────────────┐
           │                       │                       │
           ▼                       ▼                       ▼
┌─────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐
│   EU (Frankfurt)    │ │   US (Ashburn)      │ │   Asia (Singapore)  │
│                     │ │                     │ │                     │
│  ┌───────────────┐  │ │  ┌───────────────┐  │ │  ┌───────────────┐  │
│  │ Load Balancer │  │ │  │ Load Balancer │  │ │  │ Load Balancer │  │
│  └───────┬───────┘  │ │  └───────┬───────┘  │ │  └───────┬───────┘  │
│          │          │ │          │          │ │          │          │
│  ┌───────┴───────┐  │ │  ┌───────┴───────┐  │ │  ┌───────┴───────┐  │
│  │ Customer EU-1 │  │ │  │ Customer US-1 │  │ │  │Customer Asia-1│  │
│  │ Customer EU-2 │  │ │  │ Customer US-2 │  │ │  │Customer Asia-2│  │
│  └───────────────┘  │ │  └───────────────┘  │ │  └───────────────┘  │
│                     │ │                     │ │                     │
│  ┌───────────────┐  │ │  ┌───────────────┐  │ │  ┌───────────────┐  │
│  │  Prometheus   │  │ │  │  Prometheus   │  │ │  │  Prometheus   │  │
│  │  + Grafana    │  │ │  │  + Grafana    │  │ │  │  + Grafana    │  │
│  └───────────────┘  │ │  └───────────────┘  │ │  └───────────────┘  │
└─────────────────────┘ └─────────────────────┘ └─────────────────────┘
```

## Old Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Hetzner Cloud                             │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                Private Network (10.0.0.0/16)           │ │
│  │                                                        │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐            │ │
│  │  │Customer A│  │Customer B│  │Customer C│            │ │
│  │  │ bunqueue │  │ bunqueue │  │ bunqueue │            │ │
│  │  │ :6789/90 │  │ :6789/90 │  │ :6789/90 │            │ │
│  │  │ :9091    │  │ :9091    │  │ :9091    │            │ │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘            │ │
│  │       │             │             │                   │ │
│  │       └─────────────┼─────────────┘                   │ │
│  │                     │ metrics                         │ │
│  │                     ▼                                 │ │
│  │            ┌─────────────────┐                        │ │
│  │            │   Monitoring    │                        │ │
│  │            │  Prometheus     │                        │ │
│  │            │  Grafana :3000  │                        │ │
│  │            │  Alertmanager   │                        │ │
│  │            └─────────────────┘                        │ │
│  │                                                        │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Pricing (Hetzner)

| Plan       | Server  | vCPU | RAM  | Disk  | Price     |
|------------|---------|------|------|-------|-----------|
| Starter    | CX22    | 2    | 4GB  | 40GB  | ~€4.5/mo  |
| Pro        | CX32    | 4    | 8GB  | 80GB  | ~€9/mo    |
| Enterprise | CX42    | 8    | 16GB | 160GB | ~€18/mo   |
| Monitoring | CX22    | 2    | 4GB  | 40GB  | ~€4.5/mo  |

## Setup

### 1. Install Terraform

```bash
brew install terraform  # macOS
# or
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-get update && sudo apt-get install terraform
```

### 2. Configure

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 3. Deploy

```bash
terraform init
terraform plan
terraform apply
```

### 4. Access

After deployment:

```bash
# Get outputs
terraform output

# Grafana dashboard
open http://<monitoring_ip>:3000
# Login: admin / bunqueue-admin

# Customer endpoint
curl http://<customer_ip>:6790/health
```

## Adding a Customer

1. Edit `terraform.tfvars`:

```hcl
customers = {
  # ... existing customers ...

  "new-customer" = {
    plan       = "pro"
    auth_token = "generated-secure-token"
  }
}
```

2. Apply:

```bash
terraform apply
```

Terraform will:
- Create new server
- Install bunqueue
- Configure firewall
- Add to Prometheus monitoring

## Removing a Customer

1. Remove from `terraform.tfvars`
2. Run `terraform apply`

## Monitoring

### Grafana Dashboards

Pre-configured dashboards:
- bunqueue Overview (jobs/sec, queue depth, latency)
- Per-customer metrics
- Alerting status

### Alerts

Default alerts:
- Queue depth > 10000
- Job failure rate > 5%
- Server down
- Disk usage > 80%

Configure in `/opt/monitoring/alertmanager.yml` on monitoring server.

## Backup

Customer data is stored in `/var/lib/bunqueue/queue.db`.

### Manual backup:

```bash
ssh root@<customer_ip> "sqlite3 /var/lib/bunqueue/queue.db '.backup /tmp/backup.db'"
scp root@<customer_ip>:/tmp/backup.db ./backups/
```

### Automated (add to customer cloud-init):

```yaml
# S3 backup every 6 hours
S3_BACKUP_ENABLED=1
S3_BUCKET=bunqueue-backups
S3_BACKUP_INTERVAL=21600000
```

## Scaling

### Vertical (upgrade plan)

```hcl
customers = {
  "customer-id" = {
    plan = "enterprise"  # was "pro"
  }
}
```

```bash
terraform apply  # Will recreate server
```

### Horizontal (multiple instances)

Not yet supported in single-node version. Coming in bunqueue v2.0 with clustering.

## Security

- All servers in private network
- Only necessary ports exposed
- Auth tokens required for API access
- Metrics endpoint internal only
- SSH key authentication

## Troubleshooting

### Check bunqueue status

```bash
ssh root@<customer_ip> "systemctl status bunqueue"
```

### View logs

```bash
ssh root@<customer_ip> "journalctl -u bunqueue -f"
```

### Restart service

```bash
ssh root@<customer_ip> "systemctl restart bunqueue"
```

---

## Multi-Region Setup (Production)

### Prerequisites

1. Hetzner Cloud account with API token
2. Cloudflare account (Pro plan for Load Balancing)
3. Domain configured in Cloudflare

### 1. Configure Multi-Region

```bash
cp terraform.tfvars.multi-region.example terraform.tfvars
# Edit with your credentials and customers
```

### 2. Deploy

```bash
terraform init
terraform plan
terraform apply
```

### 3. How GeoDNS Works

```
User in Germany → Cloudflare → EU Pool → Frankfurt Server
User in USA     → Cloudflare → US Pool → Ashburn Server
User in Japan   → Cloudflare → Asia Pool → Singapore Server
```

Cloudflare automatically routes users to the nearest region based on:
- Geographic location
- Latency measurements
- Server health

### 4. Adding Regional Customers

```hcl
customers_regional = {
  "new-eu-customer" = {
    plan       = "pro"
    auth_token = "secret"
    region     = "eu"       # Routes to Frankfurt
  }

  "new-us-customer" = {
    plan       = "enterprise"
    auth_token = "secret"
    region     = "us"       # Routes to Ashburn
  }
}
```

### 5. Regional Failover

If a region goes down, Cloudflare automatically fails over to the next closest healthy region:

```
EU Down → Users routed to US
US Down → Users routed to EU
All Down → 503 error page (configure in Cloudflare)
```

### 6. Costs (Multi-Region)

| Component | Per Region | 3 Regions |
|-----------|------------|-----------|
| Monitoring | €4.5/mo | €13.5/mo |
| Load Balancer | €6/mo | €18/mo |
| Customer (avg) | €9/mo | €9/mo × N |
| Cloudflare LB | - | ~$20/mo |

For 10 customers across 3 regions: ~€150/mo infrastructure

### 7. Cloudflare Configuration

Required Cloudflare features:
- **DNS** (free)
- **Proxy/CDN** (free)
- **Load Balancing** (Pro plan, ~$20/mo)
- **Health Checks** (included with LB)
- **Rate Limiting** (free tier available)

### Files

```
infra/terraform/
├── main.tf                          # Base infrastructure
├── customer.tf                      # Single-region customers
├── multi-region.tf                  # Regional networks & LBs
├── customer-regional.tf             # Multi-region customers
├── cloudflare.tf                    # GeoDNS & routing
├── templates/
│   ├── monitoring-cloud-init.yml    # Prometheus/Grafana setup
│   └── bunqueue-cloud-init.yml      # bunqueue server setup
├── grafana-dashboard.json           # Pre-built dashboard
├── terraform.tfvars.example         # Single-region config
└── terraform.tfvars.multi-region.example  # Multi-region config
```
