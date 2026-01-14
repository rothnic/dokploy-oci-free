#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

command -v terraform &>/dev/null || { log "ERROR: terraform required"; exit 1; }

log "=== Terraform-Based Template Validation ==="

cat > "$TMPDIR/main.tf" << 'EOF'
locals {
  worker_ips = ["129.80.75.164", "129.80.228.116", "143.47.99.170"]
  worker_public_ips = length(local.worker_ips) > 0 ? indent(6, join("\n", local.worker_ips)) : ""
}

output "manager" {
  value = templatefile("${path.module}/manager_user_data.tpl", {
    root_authorized_keys = "ssh-ed25519 AAAA test@test"
    workers_public_ips   = local.worker_public_ips
  })
}

output "worker" {
  value = templatefile("${path.module}/worker_user_data.tpl", {
    root_authorized_keys = "ssh-ed25519 AAAA test@test"
  })
}
EOF

cp "$PROJECT_ROOT/templates/"*.tpl "$TMPDIR/"

cd "$TMPDIR"
terraform init -backend=false >/dev/null 2>&1 || { log "✗ Terraform init failed"; exit 1; }

if ! terraform apply -auto-approve >/dev/null 2>&1; then
    log "✗ Terraform template rendering failed"
    terraform apply -auto-approve 2>&1 | tail -20
    exit 1
fi
log "✓ Templates rendered successfully"

terraform output -raw manager > "$TMPDIR/manager.yml"
terraform output -raw worker > "$TMPDIR/worker.yml"

FAILURES=0
for t in manager worker; do
    f="$TMPDIR/$t.yml"
    
    if ruby -ryaml -e "YAML.load_file('$f')" 2>/dev/null; then
        log "✓ $t: Valid YAML"
    elif python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null; then
        log "✓ $t: Valid YAML"
    else
        log "✗ $t: INVALID YAML - cloud-init will reject this!"
        python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>&1 | head -10
        FAILURES=$((FAILURES + 1))
    fi
    
    head -1 "$f" | grep -q "^#cloud-config" && log "✓ $t: Has #cloud-config header" || { log "✗ $t: Missing header"; FAILURES=$((FAILURES + 1)); }
    grep -q "^packages:" "$f" && log "✓ $t: Has packages section" || { log "✗ $t: Missing packages"; FAILURES=$((FAILURES + 1)); }
    grep -q "ufw --force enable" "$f" && log "✓ $t: UFW enabled" || { log "✗ $t: UFW not enabled"; FAILURES=$((FAILURES + 1)); }
done

if grep -q "docker swarm init" "$TMPDIR/manager.yml"; then
    log "✓ manager: Has swarm init"
else
    log "✗ manager: Missing swarm init"
    FAILURES=$((FAILURES + 1))
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
    log "=== ✓ All validations passed ==="
else
    log "=== ✗ $FAILURES validation(s) failed ==="
    exit 1
fi
