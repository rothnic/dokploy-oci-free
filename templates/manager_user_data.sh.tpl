#!/bin/bash
set -e

ADMIN_EMAIL="${admin_email}"
ADMIN_PASSWORD="${admin_password}"
ADMIN_FIRST_NAME="${admin_first_name}"
ADMIN_LAST_NAME="${admin_last_name}"

cat > /opt/dokploy-setup.sh << 'SETUPEOF'
#!/bin/bash
set -e

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a /var/log/dokploy-setup.log; }

log "Starting Dokploy Manager setup..."

mkdir -p /root/.ssh
cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
chown root:root /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

cat > /etc/ssh/sshd_config.d/99-dokploy-hardening.conf << 'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF

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

apt_retry ufw fail2ban ca-certificates curl iptables-persistent netfilter-persistent ncat jq

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
ufw allow 9999/tcp
ufw --force enable

curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

iptables -I INPUT 1 -p tcp --dport 9999 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 2377 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 4789 -j ACCEPT
iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
iptables -A FORWARD -j REJECT --reject-with icmp-host-prohibited
netfilter-persistent save

log "Installing Dokploy..."
docker swarm init --advertise-addr $(hostname -I | awk '{print $1}') 2>/dev/null || log "Swarm already initialized"
curl -sSL https://dokploy.com/install.sh | sh

log "Waiting for Dokploy API to be ready..."
until curl -sf --connect-timeout 5 http://localhost:3000/ >/dev/null 2>&1; do
    log "Dokploy not ready, waiting..."
    sleep 10
done
log "Dokploy API is ready!"

sleep 15

CREDS_FILE="/opt/dokploy-credentials.json"
ADMIN_EMAIL_VAR="$1"
ADMIN_PASSWORD_VAR="$2"
ADMIN_FIRST_NAME_VAR="$3"
ADMIN_LAST_NAME_VAR="$4"

log "Creating admin user: $ADMIN_EMAIL_VAR"
SIGNUP_RESPONSE=$(curl -sf -X POST "http://localhost:3000/api/auth/sign-up/email" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$ADMIN_EMAIL_VAR\",\"password\":\"$ADMIN_PASSWORD_VAR\",\"name\":\"$ADMIN_FIRST_NAME_VAR\",\"lastName\":\"$ADMIN_LAST_NAME_VAR\"}" 2>&1) || {
    log "Signup response: $SIGNUP_RESPONSE"
    if echo "$SIGNUP_RESPONSE" | grep -qi "already"; then
        log "Admin user already exists, proceeding to login..."
    else
        log "Warning: signup may have failed, trying to login anyway..."
    fi
}
log "Admin user created or exists"

log "Logging in..."
LOGIN_RESPONSE=$(curl -sf -X POST "http://localhost:3000/api/auth/sign-in/email" \
    -H "Content-Type: application/json" \
    -c /tmp/cookies.txt \
    -d "{\"email\":\"$ADMIN_EMAIL_VAR\",\"password\":\"$ADMIN_PASSWORD_VAR\"}" 2>&1)
log "Login response: $LOGIN_RESPONSE"

SESSION_TOKEN=$(cat /tmp/cookies.txt | grep "better-auth.session_token" | awk '{print $NF}')
if [ -z "$SESSION_TOKEN" ]; then
    log "ERROR: Failed to get session token"
    exit 1
fi
log "Session token obtained"

log "Creating API key..."
API_KEY_RESPONSE=$(curl -sf -X POST "http://localhost:3000/api/trpc/user.createApiKey?batch=1" \
    -H "Content-Type: application/json" \
    -b "better-auth.session_token=$SESSION_TOKEN" \
    -d '{"0":{"json":{"name":"AutoSetup","expiresIn":null,"prefix":"auto","metadata":{},"rateLimitEnabled":false,"rateLimitTimeWindow":null,"rateLimitMax":null,"remaining":null,"refillAmount":null,"refillInterval":null},"meta":{"values":{"expiresIn":["undefined"],"rateLimitTimeWindow":["undefined"],"rateLimitMax":["undefined"],"remaining":["undefined"],"refillAmount":["undefined"],"refillInterval":["undefined"]}}}}' 2>&1)
log "API key response: $API_KEY_RESPONSE"

API_KEY=$(echo "$API_KEY_RESPONSE" | jq -r '.[0].result.data.json.key' 2>/dev/null)
if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
    log "ERROR: Failed to create API key"
    exit 1
fi
log "API key created: $${API_KEY:0:20}..."

log "Generating SSH key pair..."
SSH_GEN_RESPONSE=$(curl -sf -X POST "http://localhost:3000/api/trpc/sshKey.generate?batch=1" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -d '{"0":{"json":{"type":"ed25519"}}}' 2>&1)
log "SSH generate response: $SSH_GEN_RESPONSE"

PUBLIC_KEY=$(echo "$SSH_GEN_RESPONSE" | jq -r '.[0].result.data.json.publicKey' 2>/dev/null)
PRIVATE_KEY=$(echo "$SSH_GEN_RESPONSE" | jq -r '.[0].result.data.json.privateKey' 2>/dev/null)
if [ -z "$PUBLIC_KEY" ] || [ "$PUBLIC_KEY" = "null" ]; then
    log "ERROR: Failed to generate SSH key"
    exit 1
fi
log "SSH key pair generated"

log "Creating SSH key in Dokploy..."
ESCAPED_PUBLIC=$(echo "$PUBLIC_KEY" | jq -Rs .)
ESCAPED_PRIVATE=$(echo "$PRIVATE_KEY" | jq -Rs .)
SSH_CREATE_RESPONSE=$(curl -sf -X POST "http://localhost:3000/api/trpc/sshKey.create?batch=1" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -d "{\"0\":{\"json\":{\"name\":\"OCI-Workers\",\"publicKey\":$ESCAPED_PUBLIC,\"privateKey\":$ESCAPED_PRIVATE}}}" 2>&1)
log "SSH create response: $SSH_CREATE_RESPONSE"

SSH_KEY_ID=$(echo "$SSH_CREATE_RESPONSE" | jq -r '.[0].result.data.json.sshKeyId' 2>/dev/null)
if [ -z "$SSH_KEY_ID" ] || [ "$SSH_KEY_ID" = "null" ]; then
    log "ERROR: Failed to create SSH key in Dokploy"
    exit 1
fi
log "SSH key created with ID: $SSH_KEY_ID"

echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
log "Public key added to root's authorized_keys"

cat > "$CREDS_FILE" << EOF
{
    "api_key": "$API_KEY",
    "ssh_key_id": "$SSH_KEY_ID",
    "public_key": $(echo "$PUBLIC_KEY" | jq -Rs .)
}
EOF
chmod 600 "$CREDS_FILE"
log "Credentials saved to $CREDS_FILE"

log "Starting credential server on port 9999..."
mkdir -p /opt/dokploy-server

cat > /etc/systemd/system/dokploy-token-server.service << 'EOF'
[Unit]
Description=Dokploy Token and Credentials Server
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/bin/bash -c 'cd /opt && python3 -m http.server 9999 &>/dev/null & PYPID=$!; while true; do sleep 5; done'
ExecStartPre=/bin/bash -c 'mkdir -p /opt/api; ln -sf /opt/dokploy-credentials.json /opt/api/credentials 2>/dev/null || true'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create a simple API endpoint script that runs as a proper HTTP server
cat > /opt/start-token-server.sh << 'SERVEREOF'
#!/bin/bash
CREDS_FILE="/opt/dokploy-credentials.json"

# Create API directory
mkdir -p /opt/api

update_endpoints() {
    # Token endpoint
    SWARM_TOKEN=$(docker swarm join-token worker -q 2>/dev/null || echo "NOT_READY")
    MANAGER_IP=$(hostname -I | awk '{print $1}')
    if [ "$SWARM_TOKEN" != "NOT_READY" ]; then
        echo "docker swarm join --token $SWARM_TOKEN $MANAGER_IP:2377" > /opt/api/token
    else
        echo "NOT_READY" > /opt/api/token
    fi
    
    # Credentials endpoint
    if [ -f "$CREDS_FILE" ]; then
        cp "$CREDS_FILE" /opt/api/credentials
    else
        echo '{"error": "not_ready"}' > /opt/api/credentials
    fi
    
    # Public key endpoint
    if [ -f "$CREDS_FILE" ]; then
        jq -r '.public_key // "NOT_READY"' "$CREDS_FILE" > /opt/api/public-key 2>/dev/null || echo "NOT_READY" > /opt/api/public-key
    else
        echo "NOT_READY" > /opt/api/public-key
    fi
}

# Initial update
update_endpoints

# Start simple HTTP server in background
cd /opt/api
python3 -m http.server 9999 &
SERVER_PID=$!

# Keep updating endpoints every 10 seconds
while true; do
    sleep 10
    update_endpoints
done
SERVEREOF
chmod +x /opt/start-token-server.sh

# Update the service to use our script
cat > /etc/systemd/system/dokploy-token-server.service << 'EOF'
[Unit]
Description=Dokploy Token and Credentials Server
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/opt/start-token-server.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dokploy-token-server
systemctl start dokploy-token-server
log "Token server started on port 9999"

log "Dokploy Manager setup complete!"
touch /opt/dokploy-setup-complete
SETUPEOF

chmod +x /opt/dokploy-setup.sh

cat > /etc/systemd/system/dokploy-setup.service << EOF
[Unit]
Description=Dokploy Initial Setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/opt/dokploy-setup-complete

[Service]
Type=oneshot
ExecStart=/opt/dokploy-setup.sh "$ADMIN_EMAIL" "$ADMIN_PASSWORD" "$ADMIN_FIRST_NAME" "$ADMIN_LAST_NAME"
RemainAfterExit=yes
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dokploy-setup
systemctl start dokploy-setup
