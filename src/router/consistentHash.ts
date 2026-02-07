/**
 * Consistent Hashing Ring for distributing queues across nodes
 */

import { createHash } from 'crypto';

interface Node {
  id: string;
  host: string;
  port: number;
  weight: number;
  healthy: boolean;
}

interface VirtualNode {
  hash: number;
  nodeId: string;
}

export class ConsistentHashRing {
  private ring: VirtualNode[] = [];
  private nodes: Map<string, Node> = new Map();
  private virtualNodesPerNode = 150; // More virtual nodes = better distribution

  addNode(node: Node): void {
    this.nodes.set(node.id, node);
    this.rebuildRing();
  }

  removeNode(nodeId: string): void {
    this.nodes.delete(nodeId);
    this.rebuildRing();
  }

  updateNodeHealth(nodeId: string, healthy: boolean): void {
    const node = this.nodes.get(nodeId);
    if (node) {
      node.healthy = healthy;
      this.rebuildRing();
    }
  }

  private rebuildRing(): void {
    this.ring = [];

    for (const [nodeId, node] of this.nodes) {
      if (!node.healthy) continue;

      // Create virtual nodes based on weight
      const virtualCount = this.virtualNodesPerNode * node.weight;

      for (let i = 0; i < virtualCount; i++) {
        const hash = this.hash(`${nodeId}:${i}`);
        this.ring.push({ hash, nodeId });
      }
    }

    // Sort by hash for binary search
    this.ring.sort((a, b) => a.hash - b.hash);
  }

  getNode(key: string): Node | null {
    if (this.ring.length === 0) return null;

    const hash = this.hash(key);

    // Binary search for first node with hash >= key hash
    let left = 0;
    let right = this.ring.length - 1;

    while (left < right) {
      const mid = Math.floor((left + right) / 2);
      if (this.ring[mid].hash < hash) {
        left = mid + 1;
      } else {
        right = mid;
      }
    }

    // Wrap around if we're past the last node
    const index = this.ring[left].hash >= hash ? left : 0;
    const nodeId = this.ring[index].nodeId;

    return this.nodes.get(nodeId) || null;
  }

  // Get N nodes for replication
  getNodes(key: string, count: number): Node[] {
    if (this.ring.length === 0) return [];

    const hash = this.hash(key);
    const result: Node[] = [];
    const seen = new Set<string>();

    // Find starting position
    let index = 0;
    for (let i = 0; i < this.ring.length; i++) {
      if (this.ring[i].hash >= hash) {
        index = i;
        break;
      }
    }

    // Collect unique nodes
    for (let i = 0; i < this.ring.length && result.length < count; i++) {
      const pos = (index + i) % this.ring.length;
      const nodeId = this.ring[pos].nodeId;

      if (!seen.has(nodeId)) {
        seen.add(nodeId);
        const node = this.nodes.get(nodeId);
        if (node) result.push(node);
      }
    }

    return result;
  }

  private hash(key: string): number {
    const hash = createHash('md5').update(key).digest();
    // Use first 4 bytes as unsigned 32-bit integer
    return hash.readUInt32BE(0);
  }

  getStats(): { totalNodes: number; healthyNodes: number; virtualNodes: number } {
    let healthyNodes = 0;
    for (const node of this.nodes.values()) {
      if (node.healthy) healthyNodes++;
    }

    return {
      totalNodes: this.nodes.size,
      healthyNodes,
      virtualNodes: this.ring.length,
    };
  }
}
