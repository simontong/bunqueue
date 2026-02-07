package router

import (
	"hash/fnv"

	"github.com/egeominotti/bunqueue/router-go/discovery"
	"github.com/egeominotti/bunqueue/router-go/hashring"
)

type Router struct {
	ring      *hashring.HashRing
	discovery *discovery.EtcdDiscovery
}

type RouteResult struct {
	Node     *hashring.Node
	Fallback *hashring.Node
}

func New(ring *hashring.HashRing, disc *discovery.EtcdDiscovery) *Router {
	return &Router{
		ring:      ring,
		discovery: disc,
	}
}

func (r *Router) Route(customerID, queueName string) *RouteResult {
	key := customerID + ":" + queueName

	// 1. Check customer-specific nodes
	customerNodes := r.discovery.GetCustomerNodes(customerID)
	if len(customerNodes) > 0 {
		nodeID := r.hashAmongNodes(key, customerNodes)
		node := r.ring.GetNode(nodeID)
		if node != nil {
			return &RouteResult{
				Node:     node,
				Fallback: r.getFallback(node.ID),
			}
		}
	}

	// 2. Fall back to global consistent hashing
	node := r.ring.GetNode(key)
	if node == nil {
		return nil
	}

	return &RouteResult{
		Node:     node,
		Fallback: r.getFallback(node.ID),
	}
}

func (r *Router) hashAmongNodes(key string, nodeIDs []string) string {
	if len(nodeIDs) == 0 {
		return ""
	}
	if len(nodeIDs) == 1 {
		return nodeIDs[0]
	}

	h := fnv.New32a()
	h.Write([]byte(key))
	idx := int(h.Sum32()) % len(nodeIDs)
	return nodeIDs[idx]
}

func (r *Router) getFallback(excludeID string) *hashring.Node {
	// Get next node in ring for fallback
	nodes := r.ring.GetNodes(excludeID, 2)
	for _, node := range nodes {
		if node.ID != excludeID {
			return node
		}
	}
	return nil
}

func (r *Router) Stats() map[string]interface{} {
	total, healthy, virtual := r.ring.Stats()
	return map[string]interface{}{
		"totalNodes":   total,
		"healthyNodes": healthy,
		"virtualNodes": virtual,
	}
}
