#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RENDERED_DIR="$SCRIPT_DIR/rendered"
SSH_DIR="$SCRIPT_DIR/ssh-keys"

usage() {
    cat <<EOF
Usage: $0 [command]

Commands:
  setup     Generate SSH keys and render cloud-config templates
  start     Start the Docker simulation environment
  stop      Stop and remove containers
  logs      Show logs from all containers
  status    Check status of simulated environment
  test      Run validation tests
  shell     Open shell in manager container
  clean     Remove all test artifacts

Example:
  $0 setup    # First-time setup
  $0 start    # Start containers
  $0 test     # Validate setup
  $0 stop     # Stop containers
EOF
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

setup_ssh_keys() {
    log "Setting up SSH keys..."
    mkdir -p "$SSH_DIR"
    
    if [ ! -f "$SSH_DIR/id_rsa" ]; then
        ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N "" -C "dokploy-test"
        log "Generated new SSH keypair"
    else
        log "SSH keys already exist"
    fi
}

render_templates() {
    log "Rendering cloud-config templates..."
    mkdir -p "$RENDERED_DIR"
    
    local pub_key
    pub_key=$(cat "$SSH_DIR/id_rsa.pub")
    
    export TF_VAR_root_authorized_keys="$pub_key"
    export TF_VAR_workers_public_ips="      172.28.0.11
      172.28.0.12"
    
    envsubst_template() {
        local input=$1
        local output=$2
        awk '{
            while (match($0, /\$\{[^}]+\}/)) {
                varname = substr($0, RSTART+2, RLENGTH-3)
                envvar = ENVIRON[varname]
                if (envvar == "") envvar = ENVIRON["TF_VAR_" varname]
                $0 = substr($0, 1, RSTART-1) envvar substr($0, RSTART+RLENGTH)
            }
            print
        }' "$input" > "$output"
    }
    
    envsubst_template "$PROJECT_ROOT/templates/manager_user_data.tpl" "$RENDERED_DIR/manager-user-data.yml"
    envsubst_template "$PROJECT_ROOT/templates/worker_user_data.tpl" "$RENDERED_DIR/worker-user-data.yml"
    
    log "Rendered templates to $RENDERED_DIR"
    
    log "Validating YAML syntax..."
    for f in "$RENDERED_DIR"/*.yml; do
        if ruby -ryaml -e "YAML.load_file('$f')" 2>/dev/null; then
            log "  ✓ $(basename "$f") is valid YAML"
        elif python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null; then
            log "  ✓ $(basename "$f") is valid YAML"
        elif head -1 "$f" | grep -q "^#cloud-config"; then
            log "  ⚠ $(basename "$f") - skipping validation (no yaml parser available)"
        else
            log "  ✗ $(basename "$f") has YAML errors or missing header"
            return 1
        fi
    done
}

cmd_setup() {
    log "=== Setting up test environment ==="
    setup_ssh_keys
    render_templates
    log "=== Setup complete ==="
    log "Run '$0 start' to launch containers"
}

cmd_start() {
    log "=== Starting Docker simulation ==="
    cd "$SCRIPT_DIR"
    
    if [ ! -f "$RENDERED_DIR/manager-user-data.yml" ]; then
        log "Templates not rendered. Running setup first..."
        cmd_setup
    fi
    
    docker compose up -d --build
    
    log "Containers starting..."
    log "Manager: http://localhost:3000 (Dokploy UI)"
    log "SSH: ssh -p 2222 -i $SSH_DIR/id_rsa root@localhost"
    log ""
    log "Run '$0 logs' to watch progress"
    log "Run '$0 test' after ~2 minutes to validate"
}

cmd_stop() {
    log "=== Stopping Docker simulation ==="
    cd "$SCRIPT_DIR"
    docker compose down -v
    log "Containers stopped and volumes removed"
}

cmd_logs() {
    cd "$SCRIPT_DIR"
    docker compose logs -f
}

cmd_status() {
    log "=== Container Status ==="
    cd "$SCRIPT_DIR"
    docker compose ps
    
    echo ""
    log "=== Cloud-init Status ==="
    for container in dokploy-manager dokploy-worker1 dokploy-worker2; do
        if docker ps -q -f name="$container" | grep -q .; then
            echo "--- $container ---"
            docker exec "$container" cloud-init status 2>/dev/null || echo "cloud-init not ready"
        fi
    done
    
    echo ""
    log "=== Docker Swarm Status ==="
    if docker exec dokploy-manager docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
        docker exec dokploy-manager docker node ls 2>/dev/null || true
    else
        echo "Swarm not initialized yet"
    fi
}

cmd_test() {
    log "=== Running Validation Tests ==="
    cd "$SCRIPT_DIR"
    
    local failures=0
    
    test_check() {
        local name=$1
        local cmd=$2
        if eval "$cmd" >/dev/null 2>&1; then
            echo "✓ $name"
        else
            echo "✗ $name"
            ((failures++)) || true
        fi
    }
    
    echo "--- Manager Tests ---"
    test_check "Manager container running" "docker ps -q -f name=dokploy-manager | grep -q ."
    test_check "Docker running in manager" "docker exec dokploy-manager docker info"
    test_check "SSH keys installed (root)" "docker exec dokploy-manager test -f /root/.ssh/authorized_keys"
    test_check "SSH keys installed (ubuntu)" "docker exec dokploy-manager test -f /home/ubuntu/.ssh/authorized_keys"
    test_check "UFW enabled" "docker exec dokploy-manager ufw status | grep -q 'Status: active'"
    test_check "Fail2ban running" "docker exec dokploy-manager systemctl is-active fail2ban"
    test_check "SSH hardening config" "docker exec dokploy-manager test -f /etc/ssh/sshd_config.d/99-dokploy-hardening.conf"
    test_check "Swarm initialized" "docker exec dokploy-manager docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active"
    test_check "Worker IPs file exists" "docker exec dokploy-manager test -f /etc/swarm/workers-public.txt"
    
    echo ""
    echo "--- Worker Tests ---"
    for worker in dokploy-worker1 dokploy-worker2; do
        echo "[$worker]"
        test_check "Container running" "docker ps -q -f name=$worker | grep -q ."
        test_check "Docker running" "docker exec $worker docker info"
        test_check "SSH keys (root)" "docker exec $worker test -f /root/.ssh/authorized_keys"
        test_check "UFW enabled" "docker exec $worker ufw status | grep -q 'Status: active'"
    done
    
    echo ""
    echo "--- Swarm Membership ---"
    if docker exec dokploy-manager docker node ls 2>/dev/null; then
        local node_count
        node_count=$(docker exec dokploy-manager docker node ls -q 2>/dev/null | wc -l)
        if [ "$node_count" -ge 3 ]; then
            echo "✓ All 3 nodes in swarm"
        else
            echo "✗ Only $node_count nodes in swarm (expected 3)"
            ((failures++)) || true
        fi
    else
        echo "✗ Could not list swarm nodes"
        ((failures++)) || true
    fi
    
    echo ""
    if [ "$failures" -eq 0 ]; then
        log "=== All tests passed ==="
    else
        log "=== $failures test(s) failed ==="
        return 1
    fi
}

cmd_shell() {
    local container="${1:-dokploy-manager}"
    log "Opening shell in $container..."
    docker exec -it "$container" bash
}

cmd_clean() {
    log "=== Cleaning test artifacts ==="
    cd "$SCRIPT_DIR"
    docker compose down -v 2>/dev/null || true
    rm -rf "$RENDERED_DIR" "$SSH_DIR"
    log "Cleaned up rendered templates and SSH keys"
}

case "${1:-}" in
    setup)  cmd_setup ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    logs)   cmd_logs ;;
    status) cmd_status ;;
    test)   cmd_test ;;
    shell)  cmd_shell "${2:-}" ;;
    clean)  cmd_clean ;;
    *)      usage ;;
esac
