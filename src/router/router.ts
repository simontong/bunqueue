/**
 * bunqueue Router
 *
 * Routes requests to the correct bunqueue node based on:
 * 1. Customer ID → dedicated node(s)
 * 2. Queue name → consistent hashing
 */

import { ConsistentHashRing } from './consistentHash';

interface NodeConfig {
  id: string;
  host: string;
  tcpPort: number;
  httpPort: number;
  weight: number;
  region: string;
}

interface CustomerMapping {
  customerId: string;
  nodeIds: string[]; // Dedicated nodes for this customer
  queues?: Map<string, string>; // Optional: specific queue → node mapping
}

interface RoutingResult {
  node: NodeConfig;
  fallback?: NodeConfig;
}

export class BunqueueRouter {
  private hashRing: ConsistentHashRing;
  private nodes: Map<string, NodeConfig> = new Map();
  private customerMappings: Map<string, CustomerMapping> = new Map();
  private healthCheckInterval: Timer | null = null;

  constructor(private config: { healthCheckIntervalMs: number }) {
    this.hashRing = new ConsistentHashRing();
  }

  // ============ Node Management ============

  registerNode(node: NodeConfig): void {
    this.nodes.set(node.id, node);
    this.hashRing.addNode({
      id: node.id,
      host: node.host,
      port: node.httpPort,
      weight: node.weight,
      healthy: true,
    });

    console.log(`[Router] Registered node: ${node.id} at ${node.host}`);
  }

  unregisterNode(nodeId: string): void {
    this.nodes.delete(nodeId);
    this.hashRing.removeNode(nodeId);
    console.log(`[Router] Unregistered node: ${nodeId}`);
  }

  // ============ Customer Mapping ============

  setCustomerMapping(mapping: CustomerMapping): void {
    this.customerMappings.set(mapping.customerId, mapping);
    console.log(
      `[Router] Customer ${mapping.customerId} mapped to nodes: ${mapping.nodeIds.join(', ')}`
    );
  }

  // ============ Routing ============

  route(customerId: string, queueName: string): RoutingResult | null {
    // 1. Check customer-specific mapping
    const customerMapping = this.customerMappings.get(customerId);

    if (customerMapping) {
      // Check if queue has specific node
      if (customerMapping.queues?.has(queueName)) {
        const nodeId = customerMapping.queues.get(queueName)!;
        const node = this.nodes.get(nodeId);
        if (node) {
          return { node, fallback: this.getFallback(nodeId) };
        }
      }

      // Use customer's dedicated nodes with consistent hashing
      const key = `${customerId}:${queueName}`;
      const nodeId = this.hashAmongNodes(key, customerMapping.nodeIds);
      const node = nodeId ? this.nodes.get(nodeId) : null;

      if (node) {
        return { node, fallback: this.getFallback(nodeId) };
      }
    }

    // 2. Fall back to global consistent hashing
    const key = `${customerId}:${queueName}`;
    const ringNode = this.hashRing.getNode(key);

    if (ringNode) {
      const node = this.nodes.get(ringNode.id);
      if (node) {
        return { node, fallback: this.getFallback(ringNode.id) };
      }
    }

    return null;
  }

  private hashAmongNodes(key: string, nodeIds: string[]): string | null {
    if (nodeIds.length === 0) return null;
    if (nodeIds.length === 1) return nodeIds[0];

    // Simple hash-based selection among customer's nodes
    let hash = 0;
    for (let i = 0; i < key.length; i++) {
      hash = (hash * 31 + key.charCodeAt(i)) >>> 0;
    }

    return nodeIds[hash % nodeIds.length];
  }

  private getFallback(excludeNodeId: string): NodeConfig | undefined {
    for (const node of this.nodes.values()) {
      if (node.id !== excludeNodeId) {
        return node;
      }
    }
    return undefined;
  }

  // ============ Health Checks ============

  startHealthChecks(): void {
    if (this.healthCheckInterval) return;

    this.healthCheckInterval = setInterval(async () => {
      await this.checkAllNodes();
    }, this.config.healthCheckIntervalMs);

    console.log(`[Router] Health checks started (every ${this.config.healthCheckIntervalMs}ms)`);
  }

  stopHealthChecks(): void {
    if (this.healthCheckInterval) {
      clearInterval(this.healthCheckInterval);
      this.healthCheckInterval = null;
    }
  }

  private async checkAllNodes(): Promise<void> {
    const checks = Array.from(this.nodes.values()).map(async (node) => {
      const healthy = await this.checkNode(node);
      this.hashRing.updateNodeHealth(node.id, healthy);

      if (!healthy) {
        console.warn(`[Router] Node ${node.id} is unhealthy`);
      }
    });

    await Promise.all(checks);
  }

  private async checkNode(node: NodeConfig): Promise<boolean> {
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 5000);

      const response = await fetch(`http://${node.host}:${node.httpPort}/health`, {
        signal: controller.signal,
      });

      clearTimeout(timeout);
      return response.ok;
    } catch {
      return false;
    }
  }

  // ============ Stats ============

  getStats() {
    const ringStats = this.hashRing.getStats();

    return {
      ...ringStats,
      customers: this.customerMappings.size,
      nodes: Array.from(this.nodes.values()).map((n) => ({
        id: n.id,
        host: n.host,
        region: n.region,
      })),
    };
  }
}
