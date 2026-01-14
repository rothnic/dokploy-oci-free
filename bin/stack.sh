#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f "$PROJECT_ROOT/.env.local" ]] && source "$PROJECT_ROOT/.env.local"

: "${OCI_STACK_ID:?Set OCI_STACK_ID in .env.local}"
: "${OCI_COMPARTMENT_ID:?Set OCI_COMPARTMENT_ID in .env.local}"
: "${OCI_SSH_PRIVATE_KEY:=$HOME/.ssh/id_ed25519}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠️  $*" >&2; }
err() { echo "[$(date '+%H:%M:%S')] ❌ $*" >&2; }

# Safety check: warn about uncommitted changes that won't be deployed
check_uncommitted_changes() {
    local force="${1:-false}"
    cd "$PROJECT_ROOT"
    
    # Check for uncommitted changes to tracked files
    local changes
    changes=$(git status --porcelain 2>/dev/null | grep -E '^( M|M |MM|A |AM)' | grep -vE '^\?\?' || true)
    
    if [[ -n "$changes" ]]; then
        warn "UNCOMMITTED CHANGES DETECTED!"
        warn "These changes will NOT be deployed (git archive uses HEAD):"
        echo "$changes" | while read -r line; do
            echo "  $line"
        done
        echo ""
        
        if [[ "$force" != "true" ]]; then
            err "Commit changes first, or use --force to deploy stale code"
            err "  git add -A && git commit -m 'your message'"
            err "  $0 apply --force  # to skip this check"
            return 1
        else
            warn "Proceeding with --force (deploying committed code only)"
        fi
    fi
    return 0
}

# Safety check: warn if instances exist (for apply without prior destroy)
check_active_instances() {
    local force="${1:-false}"
    
    # Check if any compute instances are in RUNNING state
    local resources
    resources=$(oci resource-manager stack list-resources --stack-id "$OCI_STACK_ID" \
        --query 'data.items[?contains(`resource-type`, `Instance`) && `resource-state`==`RUNNING`]' \
        --raw-output 2>/dev/null || echo "[]")
    
    local count
    count=$(echo "$resources" | jq 'length' 2>/dev/null || echo "0")
    
    if [[ "$count" -gt 0 ]]; then
        warn "ACTIVE INSTANCES DETECTED ($count running)"
        warn "Apply will NOT recreate instances with new user_data!"
        warn "To deploy new user_data scripts, destroy first:"
        echo ""
        echo "  $0 destroy && $0 apply"
        echo ""
        
        if [[ "$force" != "true" ]]; then
            err "Use --force to apply anyway (won't update user_data on existing instances)"
            return 1
        else
            warn "Proceeding with --force (existing instances keep old user_data)"
        fi
    fi
    return 0
}

cmd_status() {
    log "=== Stack Status ==="
    oci resource-manager stack get --stack-id "$OCI_STACK_ID" \
        --query 'data.{name:"display-name",state:"lifecycle-state"}' --output table
    
    echo ""
    log "=== Latest Job ==="
    oci resource-manager job list --stack-id "$OCI_STACK_ID" --limit 1 \
        --query 'data[0].{operation:operation,state:"lifecycle-state",created:"time-created"}' --output table
    
    echo ""
    log "=== Stack Resources ==="
    oci resource-manager stack list-resources --stack-id "$OCI_STACK_ID" \
        --query 'data.items[*].{name:"resource-name",type:"resource-type",state:"resource-state"}' --output table 2>/dev/null || echo "No resources deployed"
}

cmd_outputs() {
    log "=== Stack Outputs ==="
    local job_id
    job_id=$(oci resource-manager job list --stack-id "$OCI_STACK_ID" --limit 1 \
        --query 'data[0].id' --raw-output 2>/dev/null)
    
    if [[ -n "$job_id" ]]; then
        oci resource-manager job-output-summary list-job-outputs --job-id "$job_id" \
            --query 'data.items[*].{name:"output-name",value:"output-value"}' --output table
    else
        echo "No jobs found"
    fi
}

cmd_get_main_ip() {
    local job_id
    job_id=$(oci resource-manager job list --stack-id "$OCI_STACK_ID" --limit 1 \
        --query 'data[0].id' --raw-output 2>/dev/null)
    
    if [[ -n "$job_id" ]]; then
        oci resource-manager job-output-summary list-job-outputs --job-id "$job_id" \
            --query 'data.items[?"output-name"==`dokploy_dashboard`]."output-value"' --raw-output 2>/dev/null | \
            grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

cmd_get_worker_ips() {
    local job_id
    job_id=$(oci resource-manager job list --stack-id "$OCI_STACK_ID" --limit 1 \
        --query 'data[0].id' --raw-output 2>/dev/null)
    
    if [[ -n "$job_id" ]]; then
        oci resource-manager job-output-summary list-job-outputs --job-id "$job_id" \
            --query 'data.items[?"output-name"==`dokploy_worker_ips`]."output-value"' --raw-output 2>/dev/null | \
            grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' '
    fi
}

cmd_apply() {
    local force="false"
    [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]] && force="true"
    
    check_uncommitted_changes "$force" || return 1
    check_active_instances "$force" || return 1
    
    log "=== Uploading Current Code ==="
    local zip_file="/tmp/dokploy-stack-$(date +%s).zip"
    cd "$PROJECT_ROOT"
    git archive --format=zip HEAD -o "$zip_file"
    log "Created: $zip_file"
    
    log "=== Updating Stack Source ==="
    oci resource-manager stack update --stack-id "$OCI_STACK_ID" \
        --config-source "$zip_file" --force 2>&1 | head -5
    
    log "=== Creating Apply Job ==="
    local job_id
    job_id=$(oci resource-manager job create-apply-job --stack-id "$OCI_STACK_ID" \
        --execution-plan-strategy AUTO_APPROVED \
        --query 'data.id' --raw-output)
    
    log "Job ID: $job_id"
    cmd_wait_job "$job_id"
    rm -f "$zip_file"
}

cmd_destroy() {
    log "=== Creating Destroy Job ==="
    local job_id
    job_id=$(oci resource-manager job create-destroy-job --stack-id "$OCI_STACK_ID" \
        --execution-plan-strategy AUTO_APPROVED \
        --query 'data.id' --raw-output)
    
    log "Job ID: $job_id"
    cmd_wait_job "$job_id"
}

cmd_wait_job() {
    local job_id="$1"
    local status=""
    
    log "Waiting for job to complete..."
    while true; do
        status=$(oci resource-manager job get --job-id "$job_id" \
            --query 'data."lifecycle-state"' --raw-output)
        
        case "$status" in
            SUCCEEDED)
                log "✓ Job completed successfully"
                return 0
                ;;
            FAILED|CANCELED)
                log "✗ Job $status"
                oci resource-manager job get --job-id "$job_id" \
                    --query 'data."failure-details"' 2>/dev/null || true
                return 1
                ;;
            *)
                echo -n "."
                sleep 10
                ;;
        esac
    done
}

cmd_ssh() {
    local target="${1:-main}"
    local ip=""
    
    case "$target" in
        main|manager) ip=$(cmd_get_ip main) ;;
        worker1|w1) ip=$(cmd_get_ip worker1) ;;
        worker2|w2) ip=$(cmd_get_ip worker2) ;;
        worker3|w3) ip=$(cmd_get_ip worker3) ;;
        *) ip="$target" ;;
    esac
    
    log "Connecting to $ip..."
    ssh -o StrictHostKeyChecking=no -i "$OCI_SSH_PRIVATE_KEY" "ubuntu@$ip"
}

cmd_get_ip() {
    local target="$1"
    oci resource-manager stack list-resources --stack-id "$OCI_STACK_ID" \
        --query "data.items[?contains(\"resource-name\", 'dokploy-$target') || contains(\"resource-name\", '$target')].\"resource-id\"" \
        --raw-output 2>/dev/null | jq -r '.[0]' | while read -r instance_id; do
        [[ -n "$instance_id" && "$instance_id" != "null" ]] && \
            oci compute instance list-vnics --instance-id "$instance_id" \
                --query 'data[0]."public-ip"' --raw-output 2>/dev/null
    done
}

cmd_check() {
    log "=== Checking Deployed Instances ==="
    
    local main_ip
    main_ip=$(cmd_get_main_ip)
    
    if [[ -z "$main_ip" ]]; then
        log "✗ Could not determine main instance IP"
        return 1
    fi
    
    log "Main IP: $main_ip"
    
    log "Checking SSH access..."
    if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        -i "$OCI_SSH_PRIVATE_KEY" "ubuntu@$main_ip" 'echo SSH_OK' 2>/dev/null | grep -q SSH_OK; then
        log "✓ SSH access works"
    else
        log "✗ SSH access failed"
        return 1
    fi
    
    log "Checking cloud-init..."
    local ci_status
    ci_status=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
        -i "$OCI_SSH_PRIVATE_KEY" "ubuntu@$main_ip" 'cloud-init status 2>/dev/null' || echo "unknown")
    log "Cloud-init: $ci_status"
    
    log "Checking Docker..."
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
        -i "$OCI_SSH_PRIVATE_KEY" "ubuntu@$main_ip" 'docker --version' 2>/dev/null; then
        log "✓ Docker installed"
    else
        log "✗ Docker NOT installed"
        log "Fetching cloud-init logs..."
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
            -i "$OCI_SSH_PRIVATE_KEY" "ubuntu@$main_ip" \
            'cat /var/log/cloud-init-output.log 2>/dev/null | tail -50' || true
        return 1
    fi
    
    log "Checking Dokploy..."
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
        -i "$OCI_SSH_PRIVATE_KEY" "ubuntu@$main_ip" 'curl -s localhost:3000 >/dev/null' 2>/dev/null; then
        log "✓ Dokploy responding on port 3000"
    else
        log "✗ Dokploy NOT responding"
        return 1
    fi
    
    log "=== All checks passed ==="
}

cmd_logs() {
    local main_ip="${1:-}"
    [[ -z "$main_ip" ]] && main_ip=$(cmd_get_main_ip)
    
    log "Fetching cloud-init logs from $main_ip..."
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
        -i "$OCI_SSH_PRIVATE_KEY" "ubuntu@$main_ip" \
        'cat /var/log/cloud-init-output.log 2>/dev/null' || echo "Could not fetch logs"
}

cmd_join() {
    log "=== Joining Workers to Swarm ==="
    "$SCRIPT_DIR/swarm-join.sh"
}

cmd_setup() {
    log "=== Setting Up Dokploy API ==="
    "$SCRIPT_DIR/dokploy-setup.sh" "$@"
}

cmd_setup() {
    log "=== Setting Up Dokploy API ==="
    "$SCRIPT_DIR/dokploy-setup.sh" "$@"
}

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  status    Show stack and job status
  outputs   Show stack outputs (IPs, URLs)
  apply     Upload code and apply stack (checks for uncommitted changes)
  destroy   Destroy all stack resources
  setup     Configure Dokploy (admin user, API key, register workers)
  join      Join workers to Docker Swarm
  check     Verify deployed instances (SSH, Docker, Dokploy)
  ssh       SSH to instance (main, worker1, worker2, worker3)
  logs      Fetch cloud-init logs from main instance

Options:
  --force   Skip safety checks (uncommitted changes, active instances)

Examples:
  $0 status
  $0 destroy && $0 apply   # Clean deploy with new user_data
  $0 apply --force         # Skip checks (use with caution)
  $0 join                  # After instances are ready
  $0 check
  $0 ssh main
EOF
}

case "${1:-}" in
    status) cmd_status ;;
    outputs) cmd_outputs ;;
    apply) cmd_apply "${2:-}" ;;
    destroy) cmd_destroy ;;
    setup) cmd_setup "${@:2}" ;;
    join) cmd_join ;;
    check) cmd_check ;;
    ssh) cmd_ssh "${2:-main}" ;;
    logs) cmd_logs "${2:-}" ;;
    *) usage ;;
esac
