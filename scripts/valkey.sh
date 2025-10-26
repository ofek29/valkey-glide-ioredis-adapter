#!/bin/bash

# Valkey Server Management - Start/stop different Valkey configurations
# Usage: ./scripts/valkey.sh {start|stop|status} {standalone|cluster|bundle}

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_usage() {
    echo "Usage: $0 {start|stop|status} {standalone|cluster|bundle|all}"
    echo ""
    echo "Commands:"
    echo "  start standalone  - Start single Valkey instance on port 6383"
    echo "  start cluster     - Start 3-node cluster on ports 17000-17002"
    echo "  start bundle      - Start Valkey on port 6380"
    echo "  start all         - Start all instances (standalone + cluster + bundle)"
    echo "  stop standalone   - Stop standalone instance"
    echo "  stop cluster      - Stop cluster nodes"
    echo "  stop bundle       - Stop bundle instance"
    echo "  stop all          - Stop all Valkey instances"
    echo "  status            - Show status of all instances"
}

check_valkey_installed() {
    if ! command -v valkey-server &> /dev/null; then
        echo -e "${RED}✗ Valkey server not found. Please install Valkey first.${NC}"
        echo ""
        echo "Installation instructions:"
        echo "  Ubuntu/Debian: sudo apt-get install valkey"
        echo "  From source:   https://github.com/valkey-io/valkey"
        exit 1
    fi
}

check_port_available() {
    local port=$1
    if nc -z localhost "$port" 2>/dev/null; then
        echo -e "${YELLOW}⚠ Port $port is already in use${NC}"
        return 1
    fi
    return 0
}

wait_for_server() {
    local port=$1
    local timeout=${2:-30}
    
    echo -n "Waiting for Valkey on port $port..."
    for i in $(seq 1 $timeout); do
        if valkey-cli -p "$port" ping 2>/dev/null | grep -q PONG; then
            echo -e " ${GREEN}ready${NC}"
            return 0
        fi
        sleep 1
        echo -n "."
    done
    echo -e " ${RED}timeout${NC}"
    return 1
}

start_standalone() {
    echo -e "${YELLOW}Starting standalone Valkey on port 6383...${NC}"
    check_valkey_installed
    
    if ! check_port_available 6383; then
        echo -e "${RED}✗ Cannot start standalone - port 6383 is in use${NC}"
        return 1
    fi
    
    # Start server
    valkey-server \
        --port 6383 \
        --daemonize yes \
        --save "" \
        --appendonly no \
        >/dev/null 2>&1
    
    if wait_for_server 6383; then
        echo -e "${GREEN}✓ Standalone Valkey ready on port 6383${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to start standalone Valkey${NC}"
        return 1
    fi
}

start_cluster() {
    echo -e "${YELLOW}Starting Valkey cluster on ports 17000-17002...${NC}"
    check_valkey_installed
    
    # Create cluster data directory
    mkdir -p .valkey-cluster
    
    # Check if all ports are available
    for port in 17000 17001 17002; do
        if ! check_port_available "$port"; then
            echo -e "${RED}✗ Cannot start cluster - port $port is in use${NC}"
            return 1
        fi
    done
    
    # Start cluster nodes
    for port in 17000 17001 17002; do
        valkey-server \
            --port "$port" \
            --daemonize yes \
            --cluster-enabled yes \
            --cluster-config-file ".valkey-cluster/nodes-$port.conf" \
            --cluster-node-timeout 5000 \
            --appendonly no \
            --save "" \
            >/dev/null 2>&1
        
        echo -e "${BLUE}  Started node on port $port${NC}"
    done
    
    # Wait for all nodes to be ready
    for port in 17000 17001 17002; do
        if ! wait_for_server "$port" 30; then
            echo -e "${RED}✗ Node on port $port failed to start${NC}"
            return 1
        fi
    done
    
    # Create cluster
    echo -e "${BLUE}  Creating cluster...${NC}"
    yes yes | valkey-cli --cluster create \
        127.0.0.1:17000 127.0.0.1:17001 127.0.0.1:17002 \
        --cluster-replicas 0 \
        >/dev/null 2>&1 || true
    
    sleep 2
    
    # Verify cluster is working
    if valkey-cli -c -p 17000 cluster info 2>/dev/null | grep -q "cluster_state:ok"; then
        echo -e "${GREEN}✓ Cluster ready on ports 17000-17002${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ Cluster started but may need initialization${NC}"
        return 0
    fi
}

start_bundle() {
    echo -e "${YELLOW}Starting Valkey bundle on port 6380...${NC}"
    check_valkey_installed
    
    if ! check_port_available 6380; then
        echo -e "${RED}✗ Cannot start bundle - port 6380 is in use${NC}"
        return 1
    fi
    
    # Start server with command-line arguments
    valkey-server \
        --port 6380 \
        --daemonize yes \
        --save "" \
        --appendonly no \
        >/dev/null 2>&1
    
    if wait_for_server 6380; then
        echo -e "${GREEN}✓ Valkey bundle ready on port 6380${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to start Valkey bundle${NC}"
        return 1
    fi
}

stop_standalone() {
    echo -e "${YELLOW}Stopping standalone Valkey...${NC}"
    valkey-cli -p 6383 shutdown nosave 2>/dev/null || true
    echo -e "${GREEN}✓ Standalone stopped${NC}"
}

stop_cluster() {
    echo -e "${YELLOW}Stopping cluster nodes...${NC}"
    for port in 17000 17001 17002; do
        valkey-cli -p "$port" shutdown nosave 2>/dev/null || true
    done
    echo -e "${GREEN}✓ Cluster stopped${NC}"
}

stop_bundle() {
    echo -e "${YELLOW}Stopping Valkey bundle...${NC}"
    valkey-cli -p 6380 shutdown nosave 2>/dev/null || true
    echo -e "${GREEN}✓ Bundle stopped${NC}"
}

stop_all() {
    stop_standalone
    stop_cluster
    stop_bundle
}

show_status() {
    echo -e "${BLUE}═══ Valkey Instance Status ═══${NC}"
    echo ""
    
    # Standalone
    echo -n "Standalone (port 6383): "
    if valkey-cli -p 6383 ping 2>/dev/null | grep -q PONG; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${RED}STOPPED${NC}"
    fi
    
    # Cluster
    echo ""
    echo "Cluster nodes:"
    for port in 17000 17001 17002; do
        echo -n "  Port $port: "
        if valkey-cli -p "$port" ping 2>/dev/null | grep -q PONG; then
            echo -e "${GREEN}RUNNING${NC}"
        else
            echo -e "${RED}STOPPED${NC}"
        fi
    done
    
    # Bundle
    echo ""
    echo -n "Bundle (port 6380): "
    if valkey-cli -p 6380 ping 2>/dev/null | grep -q PONG; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${RED}STOPPED${NC}"
    fi
    
    echo ""
}


# Main logic
case "$1" in
    start)
        case "$2" in
            standalone) start_standalone ;;
            cluster) start_cluster ;;
            bundle) start_bundle ;;
            all)
                start_standalone
                start_cluster
                start_bundle
                ;;
            *) show_usage; exit 1 ;;
        esac
        ;;
    stop)
        case "$2" in
            standalone) stop_standalone ;;
            cluster) stop_cluster ;;
            bundle) stop_bundle ;;
            all) stop_all ;;
            *) show_usage; exit 1 ;;
        esac
        ;;
    status)
        show_status
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
