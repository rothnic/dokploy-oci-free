#!/bin/bash
# entrypoint.sh - Initialize cloud-init and start systemd
set -e

echo "=== OCI Simulation Container Starting ==="
echo "Hostname: $(hostname)"
echo "Date: $(date)"

# If user-data is provided, set up cloud-init
if [ -f /var/lib/cloud/seed/nocloud-net/user-data ]; then
    echo "Found user-data, cloud-init will process it"
    
    # Create required meta-data if not present
    if [ ! -f /var/lib/cloud/seed/nocloud-net/meta-data ]; then
        cat > /var/lib/cloud/seed/nocloud-net/meta-data << EOF
instance-id: test-$(hostname)
local-hostname: $(hostname)
EOF
    fi
else
    echo "WARNING: No user-data found at /var/lib/cloud/seed/nocloud-net/user-data"
    echo "Cloud-init will run with defaults"
fi

# Clean cloud-init state for fresh run
cloud-init clean --logs 2>/dev/null || true
rm -rf /var/lib/cloud/instances/* 2>/dev/null || true

# Start Docker daemon in background if available
if command -v dockerd &> /dev/null; then
    echo "Starting Docker daemon in background..."
    dockerd > /var/log/dockerd.log 2>&1 &
    
    # Wait for Docker to be ready (up to 30 seconds)
    for i in $(seq 1 30); do
        if docker info &>/dev/null; then
            echo "Docker daemon is ready"
            break
        fi
        sleep 1
    done
fi

echo "=== Starting systemd ==="
exec "$@"
