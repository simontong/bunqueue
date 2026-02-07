package hashring

import (
	"fmt"
	"sort"
	"sync"

	"github.com/cespare/xxhash/v2"
)

type Node struct {
	ID      string
	Host    string
	Port    int
	Weight  int
	Healthy bool
}

type virtualNode struct {
	hash   uint64
	nodeID string
}

type HashRing struct {
	mu                 sync.RWMutex
	ring               []virtualNode
	nodes              map[string]*Node
	virtualNodesPerNode int
}

func New(virtualNodesPerNode int) *HashRing {
	return &HashRing{
		nodes:              make(map[string]*Node),
		virtualNodesPerNode: virtualNodesPerNode,
	}
}

func (hr *HashRing) AddNode(node *Node) {
	hr.mu.Lock()
	defer hr.mu.Unlock()

	hr.nodes[node.ID] = node
	hr.rebuildRing()
}

func (hr *HashRing) RemoveNode(nodeID string) {
	hr.mu.Lock()
	defer hr.mu.Unlock()

	delete(hr.nodes, nodeID)
	hr.rebuildRing()
}

func (hr *HashRing) UpdateHealth(nodeID string, healthy bool) {
	hr.mu.Lock()
	defer hr.mu.Unlock()

	if node, ok := hr.nodes[nodeID]; ok {
		node.Healthy = healthy
		hr.rebuildRing()
	}
}

func (hr *HashRing) rebuildRing() {
	hr.ring = hr.ring[:0]

	for nodeID, node := range hr.nodes {
		if !node.Healthy {
			continue
		}

		count := hr.virtualNodesPerNode * node.Weight
		for i := 0; i < count; i++ {
			key := fmt.Sprintf("%s:%d", nodeID, i)
			hash := xxhash.Sum64String(key)
			hr.ring = append(hr.ring, virtualNode{hash: hash, nodeID: nodeID})
		}
	}

	sort.Slice(hr.ring, func(i, j int) bool {
		return hr.ring[i].hash < hr.ring[j].hash
	})
}

func (hr *HashRing) GetNode(key string) *Node {
	hr.mu.RLock()
	defer hr.mu.RUnlock()

	if len(hr.ring) == 0 {
		return nil
	}

	hash := xxhash.Sum64String(key)

	// Binary search
	idx := sort.Search(len(hr.ring), func(i int) bool {
		return hr.ring[i].hash >= hash
	})

	// Wrap around
	if idx >= len(hr.ring) {
		idx = 0
	}

	nodeID := hr.ring[idx].nodeID
	return hr.nodes[nodeID]
}

func (hr *HashRing) GetNodes(key string, count int) []*Node {
	hr.mu.RLock()
	defer hr.mu.RUnlock()

	if len(hr.ring) == 0 {
		return nil
	}

	hash := xxhash.Sum64String(key)

	idx := sort.Search(len(hr.ring), func(i int) bool {
		return hr.ring[i].hash >= hash
	})

	if idx >= len(hr.ring) {
		idx = 0
	}

	seen := make(map[string]bool)
	result := make([]*Node, 0, count)

	for i := 0; i < len(hr.ring) && len(result) < count; i++ {
		pos := (idx + i) % len(hr.ring)
		nodeID := hr.ring[pos].nodeID

		if !seen[nodeID] {
			seen[nodeID] = true
			result = append(result, hr.nodes[nodeID])
		}
	}

	return result
}

func (hr *HashRing) Stats() (total, healthy, virtual int) {
	hr.mu.RLock()
	defer hr.mu.RUnlock()

	total = len(hr.nodes)
	for _, node := range hr.nodes {
		if node.Healthy {
			healthy++
		}
	}
	virtual = len(hr.ring)
	return
}
