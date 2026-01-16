#!/bin/bash
set -e

MANAGER_IP="${manager_private_ip}"
WORKER_NAME="${worker_name}"
WORKER_PUBLIC_IP="${worker_public_ip}"

cat > /opt/dokploy-worker-setup.sh << 'SETUPEOF'
#!/bin/bash
set -e

MANAGER_IP="$1"
WORKER_NAME="$2"
WORKER_PUBLIC_IP="$3"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a /var/log/dokploy-worker-setup.log >&2; }

log "Starting Dokploy Worker setup..."
log "Manager IP: $MANAGER_IP"
log "Worker Name: $WORKER_NAME"
log "Worker Public IP: $WORKER_PUBLIC_IP"

mkdir -p /root/.ssh
cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
chown root:root /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

cat > /etc/ssh/sshd_config.d/99-dokploy-hardening.conf << 'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin prohibit-password
EOF

systemctl restart sshd

apt_retry() {
    local attempt=0
    local delay=30
    local max_delay=600
    while true; do
        attempt=$((attempt + 1))
        log "apt-get attempt $attempt..."
        if apt-get update && apt-get install -y "$@"; then
            return 0
        fi
        log "apt-get failed, waiting $${delay}s..."
        sleep $delay
        delay=$((delay * 2))
        [ $delay -gt $max_delay ] && delay=$max_delay
    done
}

apt_retry ufw fail2ban ca-certificates curl iptables-persistent netfilter-persistent jq

cat > /etc/fail2ban/jail.d/sshd.conf << 'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF
systemctl enable fail2ban
systemctl restart fail2ban

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 81/tcp
ufw allow 443/tcp
ufw allow 444/tcp
ufw allow 2376/tcp
ufw allow 2377/tcp
ufw allow 3000/tcp
ufw allow 7946/tcp
ufw allow 7946/udp
ufw allow 4789/udp
ufw --force enable

curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

iptables -I INPUT 1 -p tcp --dport 2377 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 4789 -j ACCEPT
iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
iptables -A FORWARD -j REJECT --reject-with icmp-host-prohibited
netfilter-persistent save

log "Base setup complete, now joining swarm and registering with Dokploy..."

# Exit early if already complete (prevents duplicate registration on service restart)
if [ -f /opt/dokploy-worker-setup-complete ]; then
    log "Worker setup already complete, exiting"
    exit 0
fi

poll_manager() {
    local endpoint="$1"
    local attempt=0
    local delay=10
    local max_delay=600
    
    while true; do
        attempt=$((attempt + 1))
        log "Polling $endpoint (attempt $attempt)..."
        
        RESPONSE=$(curl -sf --connect-timeout 10 "http://$MANAGER_IP:9999/$endpoint" 2>/dev/null || echo "")
        
        if [ -n "$RESPONSE" ] && [ "$RESPONSE" != "NOT_READY" ] && [ "$RESPONSE" != "ERROR" ] && ! echo "$RESPONSE" | grep -q "error"; then
            echo "$RESPONSE"
            return 0
        fi
        
        log "Not ready, waiting $${delay}s (max 10min)..."
        sleep $delay
        delay=$((delay + 30))
        [ $delay -gt $max_delay ] && delay=$max_delay
    done
}

if docker info 2>/dev/null | grep -q "Swarm: active"; then
    log "Already in swarm"
else
    log "Joining Docker Swarm..."
    JOIN_CMD=$(poll_manager "token")
    log "Got join command: $JOIN_CMD"
    eval "$JOIN_CMD"
    log "Successfully joined swarm!"
fi

log "Fetching credentials from manager..."
CREDS=$(poll_manager "credentials")
log "Got credentials"

API_KEY=$(echo "$CREDS" | jq -r '.api_key')
SSH_KEY_ID=$(echo "$CREDS" | jq -r '.ssh_key_id')
PUBLIC_KEY=$(echo "$CREDS" | jq -r '.public_key')

if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
    log "ERROR: Failed to get API key from credentials"
    exit 1
fi
log "API Key: $${API_KEY:0:20}..."
log "SSH Key ID: $SSH_KEY_ID"

log "Adding Dokploy SSH public key to root..."
echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
log "Public key added"

MY_IP=$(hostname -I | awk '{print $1}')
log "Registering worker in Dokploy with IP: $MY_IP"

SERVER_CREATE_RESPONSE=$(curl -sf -X POST "http://$MANAGER_IP:3000/api/trpc/server.create?batch=1" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -d "{\"0\":{\"json\":{\"name\":\"$WORKER_NAME\",\"ipAddress\":\"$MY_IP\",\"port\":22,\"username\":\"root\",\"sshKeyId\":\"$SSH_KEY_ID\",\"serverType\":\"deploy\"}}}" 2>&1)
log "Server create response: $SERVER_CREATE_RESPONSE"

SERVER_ID=$(echo "$SERVER_CREATE_RESPONSE" | jq -r '.[0].result.data.json.serverId' 2>/dev/null)
if [ -z "$SERVER_ID" ] || [ "$SERVER_ID" = "null" ]; then
    log "ERROR: Failed to create server in Dokploy"
    log "Response was: $SERVER_CREATE_RESPONSE"
    exit 1
fi
log "Server created with ID: $SERVER_ID"

# Workers automatically appear in the cluster once they join swarm and register via server.create
# No separate cluster.addWorker call needed (that API is for getting swarm join commands)

log "Dokploy Worker setup complete!"
log "Server ID: $SERVER_ID"
touch /opt/dokploy-worker-setup-complete
SETUPEOF

chmod +x /opt/dokploy-worker-setup.sh

cat > /etc/systemd/system/dokploy-worker-setup.service << EOF
[Unit]
Description=Dokploy Worker Initial Setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/opt/dokploy-worker-setup-complete

[Service]
Type=oneshot
ExecStart=/opt/dokploy-worker-setup.sh "$MANAGER_IP" "$WORKER_NAME" "$WORKER_PUBLIC_IP"
RemainAfterExit=yes
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dokploy-worker-setup
systemctl start dokploy-worker-setup
