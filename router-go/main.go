package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/egeominotti/bunqueue/router-go/discovery"
	"github.com/egeominotti/bunqueue/router-go/hashring"
	"github.com/egeominotti/bunqueue/router-go/router"
)

var queuePatterns = []*regexp.Regexp{
	regexp.MustCompile(`^/(push|pull|ack|fail)/([^/]+)`),
	regexp.MustCompile(`^/queue/([^/]+)`),
	regexp.MustCompile(`^/queues/([^/]+)`),
}

func main() {
	// Config from env
	port := getEnv("ROUTER_PORT", "6800")
	etcdEndpoints := strings.Split(getEnv("ETCD_ENDPOINTS", "localhost:2379"), ",")

	log.Printf("[Router] Starting on port %s", port)
	log.Printf("[Router] etcd endpoints: %v", etcdEndpoints)

	// Initialize hash ring
	ring := hashring.New(150) // 150 virtual nodes per node

	// Initialize etcd discovery
	disc, err := discovery.NewEtcdDiscovery(etcdEndpoints, ring)
	if err != nil {
		log.Fatalf("Failed to initialize etcd discovery: %v", err)
	}
	defer disc.Close()

	// Load initial state
	ctx := context.Background()
	if err := disc.LoadInitial(ctx); err != nil {
		log.Fatalf("Failed to load initial state: %v", err)
	}

	// Watch for changes
	disc.Watch(ctx)

	// Initialize router
	r := router.New(ring, disc)

	// HTTP client for proxying
	httpClient := &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			MaxIdleConns:        100,
			MaxIdleConnsPerHost: 10,
			IdleConnTimeout:     90 * time.Second,
		},
	}

	// HTTP server
	mux := http.NewServeMux()

	// Health check
	mux.HandleFunc("/health", func(w http.ResponseWriter, req *http.Request) {
		stats := r.Stats()
		stats["status"] = "ok"
		json.NewEncoder(w).Encode(stats)
	})

	// Router stats
	mux.HandleFunc("/_router/stats", func(w http.ResponseWriter, req *http.Request) {
		json.NewEncoder(w).Encode(r.Stats())
	})

	// Proxy all other requests
	mux.HandleFunc("/", func(w http.ResponseWriter, req *http.Request) {
		// Extract customer ID
		customerID := req.Header.Get("X-Customer-ID")
		if customerID == "" {
			http.Error(w, `{"error":"Missing X-Customer-ID header"}`, http.StatusBadRequest)
			return
		}

		// Extract queue name
		queueName := extractQueueName(req.URL.Path)
		if queueName == "" {
			http.Error(w, `{"error":"Could not determine queue from request"}`, http.StatusBadRequest)
			return
		}

		// Route
		result := r.Route(customerID, queueName)
		if result == nil || result.Node == nil {
			http.Error(w, `{"error":"No healthy nodes available"}`, http.StatusServiceUnavailable)
			return
		}

		// Proxy to node
		targetURL := fmt.Sprintf("http://%s:%d%s", result.Node.Host, result.Node.Port, req.URL.RequestURI())

		proxyReq, err := http.NewRequest(req.Method, targetURL, req.Body)
		if err != nil {
			http.Error(w, `{"error":"Failed to create proxy request"}`, http.StatusInternalServerError)
			return
		}

		// Copy headers
		for key, values := range req.Header {
			for _, value := range values {
				proxyReq.Header.Add(key, value)
			}
		}

		// Execute request
		resp, err := httpClient.Do(proxyReq)
		if err != nil {
			// Try fallback
			if result.Fallback != nil {
				fallbackURL := fmt.Sprintf("http://%s:%d%s", result.Fallback.Host, result.Fallback.Port, req.URL.RequestURI())
				proxyReq, _ = http.NewRequest(req.Method, fallbackURL, req.Body)
				for key, values := range req.Header {
					for _, value := range values {
						proxyReq.Header.Add(key, value)
					}
				}
				resp, err = httpClient.Do(proxyReq)
				if err != nil {
					http.Error(w, `{"error":"All nodes unavailable"}`, http.StatusServiceUnavailable)
					return
				}
				w.Header().Set("X-Fallback", "true")
				w.Header().Set("X-Routed-To", result.Fallback.ID)
			} else {
				http.Error(w, `{"error":"Node unavailable"}`, http.StatusServiceUnavailable)
				return
			}
		} else {
			w.Header().Set("X-Routed-To", result.Node.ID)
		}
		defer resp.Body.Close()

		// Copy response headers
		for key, values := range resp.Header {
			for _, value := range values {
				w.Header().Add(key, value)
			}
		}

		// Copy status code and body
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})

	// Start server
	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Graceful shutdown
	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan

		log.Println("[Router] Shutting down...")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		server.Shutdown(ctx)
	}()

	log.Printf("[Router] Listening on :%s", port)
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatalf("Server error: %v", err)
	}
}

func extractQueueName(path string) string {
	for _, pattern := range queuePatterns {
		matches := pattern.FindStringSubmatch(path)
		if len(matches) > 0 {
			return matches[len(matches)-1]
		}
	}
	return ""
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
