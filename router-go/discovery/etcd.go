package discovery

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/egeominotti/bunqueue/router-go/hashring"
	clientv3 "go.etcd.io/etcd/client/v3"
)

const (
	nodesPrefix     = "/bunqueue/nodes/"
	customersPrefix = "/bunqueue/customers/"
)

type NodeData struct {
	Host    string `json:"host"`
	Port    int    `json:"port"`
	Weight  int    `json:"weight"`
	Region  string `json:"region"`
	Healthy bool   `json:"healthy"`
}

type CustomerData struct {
	NodeIDs []string `json:"nodeIds"`
}

type EtcdDiscovery struct {
	client    *clientv3.Client
	ring      *hashring.HashRing
	customers map[string]*CustomerData
	onChange  func()
}

func NewEtcdDiscovery(endpoints []string, ring *hashring.HashRing) (*EtcdDiscovery, error) {
	client, err := clientv3.New(clientv3.Config{
		Endpoints:   endpoints,
		DialTimeout: 5 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to connect to etcd: %w", err)
	}

	return &EtcdDiscovery{
		client:    client,
		ring:      ring,
		customers: make(map[string]*CustomerData),
	}, nil
}

func (d *EtcdDiscovery) SetOnChange(fn func()) {
	d.onChange = fn
}

func (d *EtcdDiscovery) LoadInitial(ctx context.Context) error {
	// Load nodes
	resp, err := d.client.Get(ctx, nodesPrefix, clientv3.WithPrefix())
	if err != nil {
		return fmt.Errorf("failed to load nodes: %w", err)
	}

	for _, kv := range resp.Kvs {
		nodeID := strings.TrimPrefix(string(kv.Key), nodesPrefix)
		d.handleNodeUpdate(nodeID, kv.Value)
	}

	// Load customers
	resp, err = d.client.Get(ctx, customersPrefix, clientv3.WithPrefix())
	if err != nil {
		return fmt.Errorf("failed to load customers: %w", err)
	}

	for _, kv := range resp.Kvs {
		customerID := strings.TrimPrefix(string(kv.Key), customersPrefix)
		d.handleCustomerUpdate(customerID, kv.Value)
	}

	log.Printf("[Discovery] Loaded %d nodes, %d customers", len(resp.Kvs), len(d.customers))
	return nil
}

func (d *EtcdDiscovery) Watch(ctx context.Context) {
	go d.watchNodes(ctx)
	go d.watchCustomers(ctx)
}

func (d *EtcdDiscovery) watchNodes(ctx context.Context) {
	watchChan := d.client.Watch(ctx, nodesPrefix, clientv3.WithPrefix())

	for resp := range watchChan {
		for _, event := range resp.Events {
			nodeID := strings.TrimPrefix(string(event.Kv.Key), nodesPrefix)

			switch event.Type {
			case clientv3.EventTypePut:
				d.handleNodeUpdate(nodeID, event.Kv.Value)
				log.Printf("[Discovery] Node updated: %s", nodeID)
			case clientv3.EventTypeDelete:
				d.handleNodeDelete(nodeID)
				log.Printf("[Discovery] Node deleted: %s", nodeID)
			}

			if d.onChange != nil {
				d.onChange()
			}
		}
	}
}

func (d *EtcdDiscovery) watchCustomers(ctx context.Context) {
	watchChan := d.client.Watch(ctx, customersPrefix, clientv3.WithPrefix())

	for resp := range watchChan {
		for _, event := range resp.Events {
			customerID := strings.TrimPrefix(string(event.Kv.Key), customersPrefix)

			switch event.Type {
			case clientv3.EventTypePut:
				d.handleCustomerUpdate(customerID, event.Kv.Value)
				log.Printf("[Discovery] Customer updated: %s", customerID)
			case clientv3.EventTypeDelete:
				d.handleCustomerDelete(customerID)
				log.Printf("[Discovery] Customer deleted: %s", customerID)
			}

			if d.onChange != nil {
				d.onChange()
			}
		}
	}
}

func (d *EtcdDiscovery) handleNodeUpdate(nodeID string, data []byte) {
	var nodeData NodeData
	if err := json.Unmarshal(data, &nodeData); err != nil {
		log.Printf("[Discovery] Failed to parse node data for %s: %v", nodeID, err)
		return
	}

	node := &hashring.Node{
		ID:      nodeID,
		Host:    nodeData.Host,
		Port:    nodeData.Port,
		Weight:  nodeData.Weight,
		Healthy: nodeData.Healthy,
	}

	if node.Weight == 0 {
		node.Weight = 1
	}

	d.ring.AddNode(node)
}

func (d *EtcdDiscovery) handleNodeDelete(nodeID string) {
	d.ring.RemoveNode(nodeID)
}

func (d *EtcdDiscovery) handleCustomerUpdate(customerID string, data []byte) {
	var customerData CustomerData
	if err := json.Unmarshal(data, &customerData); err != nil {
		log.Printf("[Discovery] Failed to parse customer data for %s: %v", customerID, err)
		return
	}

	d.customers[customerID] = &customerData
}

func (d *EtcdDiscovery) handleCustomerDelete(customerID string) {
	delete(d.customers, customerID)
}

func (d *EtcdDiscovery) GetCustomerNodes(customerID string) []string {
	if customer, ok := d.customers[customerID]; ok {
		return customer.NodeIDs
	}
	return nil
}

func (d *EtcdDiscovery) Close() error {
	return d.client.Close()
}
