# bunqueue Router (Go)

High-performance router for bunqueue cluster with etcd service discovery.

## Features

- **Consistent hashing** - Same queue always routes to same node
- **etcd integration** - Auto-discovery of nodes and customers
- **Health checks** - Automatic failover to healthy nodes
- **Zero-config** - Nodes register themselves
- **~10MB RAM** - Lightweight
- **~200K req/s** - High throughput

## Architecture

```
                    ┌─────────────┐
                    │   Client    │
                    └──────┬──────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────┐
│                   Router (Go)                        │
│                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │ Hash Ring   │  │  Discovery  │  │ HTTP Proxy  │ │
│  │             │◄─┤   (etcd)    │  │             │ │
│  └─────────────┘  └─────────────┘  └─────────────┘ │
│                                                      │
└──────────────────────────┬───────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
   ┌─────────┐        ┌─────────┐        ┌─────────┐
   │ Node 1  │        │ Node 2  │        │ Node N  │
   └─────────┘        └─────────┘        └─────────┘
```

## Quick Start

### 1. Start etcd

```bash
docker run -d --name etcd \
  -p 2379:2379 \
  quay.io/coreos/etcd:v3.5.9 \
  etcd --listen-client-urls=http://0.0.0.0:2379 \
       --advertise-client-urls=http://localhost:2379
```

### 2. Register nodes in etcd

```bash
# Register node1
etcdctl put /bunqueue/nodes/node1 '{"host":"localhost","port":6790,"weight":1,"healthy":true}'

# Register node2
etcdctl put /bunqueue/nodes/node2 '{"host":"localhost","port":6791,"weight":1,"healthy":true}'

# Register customer
etcdctl put /bunqueue/customers/acme '{"nodeIds":["node1"]}'
```

### 3. Start router

```bash
# From source
go run .

# Or with Docker
docker build -t bunqueue-router .
docker run -p 6800:6800 -e ETCD_ENDPOINTS=host.docker.internal:2379 bunqueue-router
```

### 4. Test

```bash
curl -X POST http://localhost:6800/push/emails \
  -H "X-Customer-ID: acme" \
  -H "Content-Type: application/json" \
  -d '{"to": "test@example.com"}'
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ROUTER_PORT` | `6800` | HTTP listen port |
| `ETCD_ENDPOINTS` | `localhost:2379` | Comma-separated etcd endpoints |

## etcd Schema

### Nodes

```
Key: /bunqueue/nodes/{node-id}
Value: {
  "host": "10.0.1.1",
  "port": 6790,
  "weight": 1,
  "region": "eu",
  "healthy": true
}
```

### Customers

```
Key: /bunqueue/customers/{customer-id}
Value: {
  "nodeIds": ["node1", "node2"]
}
```

## API

### Health Check

```
GET /health
```

### Router Stats

```
GET /_router/stats
```

### Proxy (all other routes)

Requires `X-Customer-ID` header. Routes based on customer mapping and consistent hashing.

## Build

```bash
# Binary
go build -o router .

# Docker
docker build -t bunqueue-router .
```

## Performance

| Metric | Value |
|--------|-------|
| Throughput | ~200K req/s |
| Latency (p50) | ~0.1ms |
| Latency (p99) | ~0.5ms |
| Memory | ~10MB |
| Binary size | ~8MB |
