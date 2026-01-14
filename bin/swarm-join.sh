#!/bin/bash
# Join workers to Docker Swarm
# Usage: ./bin/swarm-join.sh [MANAGER_IP] [WORKER_IP...]
#        ./bin/swarm-join.sh  (auto-detect from stack outputs)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30"

get_stack_outputs() {
    "$SCRIPT_DIR/stack.sh" outputs 2>/dev/null | grep -E "dokploy_dashboard|dokploy_worker_ips" || true
}

parse_manager_ip() {
    local outputs="$1"
    echo "$outputs" | grep "dokploy_dashboard" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

parse_worker_ips() {
    local outputs="$1"
    echo "$outputs" | grep "dokploy_worker_ips" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' '
}

wait_for_ssh() {
    local ip="$1"
    local max_attempts=30
    local attempt=1
    
    echo "  Waiting for SSH on $ip..."
    while [ $attempt -le $max_attempts ]; do
        if ssh $SSH_OPTS ubuntu@"$ip" "true" 2>/dev/null; then
            return 0
        fi
        sleep 2
        ((attempt++))
    done
    echo "  ERROR: SSH not available on $ip after $max_attempts attempts"
    return 1
}

wait_for_docker() {
    local ip="$1"
    local max_attempts=60
    local attempt=1
    
    echo "  Waiting for Docker on $ip..."
    while [ $attempt -le $max_attempts ]; do
        if ssh $SSH_OPTS ubuntu@"$ip" "sudo docker info" &>/dev/null; then
            return 0
        fi
        sleep 5
        ((attempt++))
    done
    echo "  ERROR: Docker not available on $ip after $max_attempts attempts"
    return 1
}

get_swarm_join_token() {
    local manager_ip="$1"
    ssh $SSH_OPTS ubuntu@"$manager_ip" "sudo docker swarm join-token worker -q" 2>/dev/null
}

get_manager_private_ip() {
    local manager_ip="$1"
    ssh $SSH_OPTS ubuntu@"$manager_ip" "hostname -I | awk '{print \$1}'" 2>/dev/null
}

join_worker_to_swarm() {
    local worker_ip="$1"
    local manager_private_ip="$2"
    local join_token="$3"
    
    echo "  Joining $worker_ip to swarm..."
    ssh $SSH_OPTS ubuntu@"$worker_ip" \
        "sudo docker swarm leave --force 2>/dev/null || true; sudo docker swarm join --token $join_token ${manager_private_ip}:2377" 2>/dev/null
}

main() {
    local manager_ip=""
    local worker_ips=""
    
    if [ $# -ge 2 ]; then
        manager_ip="$1"
        shift
        worker_ips="$*"
    else
        echo "Auto-detecting from stack outputs..."
        local outputs
        outputs=$(get_stack_outputs)
        
        if [ -z "$outputs" ]; then
            echo "ERROR: Could not get stack outputs. Run with explicit IPs:"
            echo "  $0 MANAGER_IP WORKER_IP [WORKER_IP...]"
            exit 1
        fi
        
        manager_ip=$(parse_manager_ip "$outputs")
        worker_ips=$(parse_worker_ips "$outputs")
        
        if [ -z "$manager_ip" ]; then
            echo "ERROR: Could not detect manager IP"
            exit 1
        fi
    fi
    
    echo "=== Docker Swarm Join ==="
    echo "Manager: $manager_ip"
    echo "Workers: $worker_ips"
    echo ""
    
    echo "[1/4] Waiting for manager SSH..."
    wait_for_ssh "$manager_ip"
    
    echo "[2/4] Waiting for manager Docker..."
    wait_for_docker "$manager_ip"
    
    echo "[3/4] Getting swarm join token..."
    local join_token
    join_token=$(get_swarm_join_token "$manager_ip")
    
    if [ -z "$join_token" ]; then
        echo "ERROR: Could not get swarm join token"
        exit 1
    fi
    echo "  Token: ${join_token:0:20}..."
    
    local manager_private_ip
    manager_private_ip=$(get_manager_private_ip "$manager_ip")
    echo "  Manager private IP: $manager_private_ip"
    
    echo "[4/4] Joining workers to swarm..."
    local success=0
    local failed=0
    
    for worker_ip in $worker_ips; do
        echo ""
        echo "Processing worker: $worker_ip"
        
        if ! wait_for_ssh "$worker_ip"; then
            ((failed++))
            continue
        fi
        
        if ! wait_for_docker "$worker_ip"; then
            ((failed++))
            continue
        fi
        
        if join_worker_to_swarm "$worker_ip" "$manager_private_ip" "$join_token"; then
            echo "  ✓ Successfully joined $worker_ip"
            ((success++))
        else
            echo "  ✗ Failed to join $worker_ip"
            ((failed++))
        fi
    done
    
    echo ""
    echo "=== Summary ==="
    echo "Joined: $success"
    echo "Failed: $failed"
    
    echo ""
    echo "Verify with: ssh ubuntu@$manager_ip 'sudo docker node ls'"
    
    [ $failed -eq 0 ]
}

main "$@"
