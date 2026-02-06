# bunqueue Cloud Infrastructure

Terraform configuration for deploying bunqueue SaaS on Hetzner Cloud.

## Architecture

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
