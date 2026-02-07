/**
 * Router HTTP Server
 *
 * Receives all requests and proxies them to the correct bunqueue node
 */

import { BunqueueRouter } from './router';

interface RouterServerConfig {
  port: number;
  nodes: Array<{
    id: string;
    host: string;
    tcpPort: number;
    httpPort: number;
    weight: number;
    region: string;
  }>;
  customers: Array<{
    customerId: string;
    nodeIds: string[];
  }>;
}

export function startRouterServer(config: RouterServerConfig) {
  const router = new BunqueueRouter({ healthCheckIntervalMs: 10000 });

  // Register all nodes
  for (const node of config.nodes) {
    router.registerNode(node);
  }

  // Setup customer mappings
  for (const customer of config.customers) {
    router.setCustomerMapping({
      customerId: customer.customerId,
      nodeIds: customer.nodeIds,
    });
  }

  // Start health checks
  router.startHealthChecks();

  const server = Bun.serve({
    port: config.port,

    async fetch(req) {
      const url = new URL(req.url);

      // Router health check
      if (url.pathname === '/health') {
        return Response.json({ status: 'ok', ...router.getStats() });
      }

      // Router stats
      if (url.pathname === '/_router/stats') {
        return Response.json(router.getStats());
      }

      // Extract customer ID and queue from request
      const customerId = req.headers.get('X-Customer-ID');
      const queueName = extractQueueName(url.pathname);

      if (!customerId) {
        return Response.json({ error: 'Missing X-Customer-ID header' }, { status: 400 });
      }

      if (!queueName) {
        return Response.json({ error: 'Could not determine queue from request' }, { status: 400 });
      }

      // Route to correct node
      const result = router.route(customerId, queueName);

      if (!result) {
        return Response.json({ error: 'No healthy nodes available' }, { status: 503 });
      }

      // Proxy request to node
      try {
        const targetUrl = `http://${result.node.host}:${result.node.httpPort}${url.pathname}${url.search}`;

        const proxyResponse = await fetch(targetUrl, {
          method: req.method,
          headers: req.headers,
          body: req.body,
        });

        // Return proxied response with routing info header
        const responseHeaders = new Headers(proxyResponse.headers);
        responseHeaders.set('X-Routed-To', result.node.id);

        return new Response(proxyResponse.body, {
          status: proxyResponse.status,
          headers: responseHeaders,
        });
      } catch (error) {
        // Try fallback node
        if (result.fallback) {
          try {
            const fallbackUrl = `http://${result.fallback.host}:${result.fallback.httpPort}${url.pathname}${url.search}`;

            const fallbackResponse = await fetch(fallbackUrl, {
              method: req.method,
              headers: req.headers,
              body: req.body,
            });

            const responseHeaders = new Headers(fallbackResponse.headers);
            responseHeaders.set('X-Routed-To', result.fallback.id);
            responseHeaders.set('X-Fallback', 'true');

            return new Response(fallbackResponse.body, {
              status: fallbackResponse.status,
              headers: responseHeaders,
            });
          } catch {
            // Fallback also failed
          }
        }

        return Response.json(
          { error: 'All nodes unavailable', node: result.node.id },
          { status: 503 }
        );
      }
    },
  });

  console.log(`[Router] Server started on port ${config.port}`);
  return server;
}

function extractQueueName(pathname: string): string | null {
  // Match patterns like:
  // /push/myqueue
  // /pull/myqueue
  // /queue/myqueue/jobs
  // /queues/myqueue

  const patterns = [
    /^\/(push|pull|ack|fail)\/([^/]+)/,
    /^\/queue\/([^/]+)/,
    /^\/queues\/([^/]+)/,
  ];

  for (const pattern of patterns) {
    const match = pathname.match(pattern);
    if (match) {
      return match[match.length - 1]; // Last capture group is queue name
    }
  }

  return null;
}

// ============ CLI Entry Point ============

if (import.meta.main) {
  const config: RouterServerConfig = {
    port: parseInt(process.env.ROUTER_PORT || '6800'),
    nodes: [],
    customers: [],
  };

  // Parse nodes from env: NODES=id1:host1:6789:6790:1:eu,id2:host2:6789:6790:1:us
  const nodesEnv = process.env.NODES || '';
  for (const nodeStr of nodesEnv.split(',').filter(Boolean)) {
    const [id, host, tcpPort, httpPort, weight, region] = nodeStr.split(':');
    config.nodes.push({
      id,
      host,
      tcpPort: parseInt(tcpPort),
      httpPort: parseInt(httpPort),
      weight: parseInt(weight) || 1,
      region: region || 'default',
    });
  }

  // Parse customers from env: CUSTOMERS=cust1:node1:node2,cust2:node3
  const customersEnv = process.env.CUSTOMERS || '';
  for (const custStr of customersEnv.split(',').filter(Boolean)) {
    const [customerId, ...nodeIds] = custStr.split(':');
    config.customers.push({ customerId, nodeIds });
  }

  if (config.nodes.length === 0) {
    console.error('No nodes configured. Set NODES environment variable.');
    console.error('Format: NODES=id:host:tcpPort:httpPort:weight:region,...');
    process.exit(1);
  }

  startRouterServer(config);
}
