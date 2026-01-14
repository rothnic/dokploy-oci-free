#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f "$PROJECT_ROOT/.env.local" ]] && source "$PROJECT_ROOT/.env.local"

: "${OCI_STACK_ID:?Set OCI_STACK_ID in .env.local}"
: "${OCI_COMPARTMENT_ID:?Set OCI_COMPARTMENT_ID in .env.local}"
: "${OCI_SSH_PRIVATE_KEY:=$HOME/.ssh/id_ed25519}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

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

usage() {
    cat <<EOF
Usage: $0 <command>

Commands:
  status    Show stack and job status
  outputs   Show stack outputs (IPs, URLs)
  apply     Upload code and apply stack
  destroy   Destroy all stack resources
  join      Join workers to Docker Swarm
  check     Verify deployed instances (SSH, Docker, Dokploy)
  ssh       SSH to instance (main, worker1, worker2, worker3)
  logs      Fetch cloud-init logs from main instance

Examples:
  $0 status
  $0 apply
  $0 join       # After instances are ready
  $0 check
  $0 ssh main
EOF
}

case "${1:-}" in
    status) cmd_status ;;
    outputs) cmd_outputs ;;
    apply) cmd_apply ;;
    destroy) cmd_destroy ;;
    join) cmd_join ;;
    check) cmd_check ;;
    ssh) cmd_ssh "${2:-main}" ;;
    logs) cmd_logs "${2:-}" ;;
    *) usage ;;
esac
