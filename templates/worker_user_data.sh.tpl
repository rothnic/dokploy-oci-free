#!/bin/bash
# Dokploy Worker Node Setup
# Uses shell script (not cloud-config) so OCI can inject SSH keys

# Create setup script that retries on failure
cat > /opt/dokploy-worker-setup.sh << 'SETUPEOF'
#!/bin/bash
set -e

MANAGER_IP="${manager_private_ip}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a /var/log/dokploy-worker-setup.log; }

log "Starting Dokploy Worker setup..."
log "Manager IP: $MANAGER_IP"

# Copy SSH keys to root
mkdir -p /root/.ssh
cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
chown root:root /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# SSH Hardening
cat > /etc/ssh/sshd_config.d/99-dokploy-hardening.conf << 'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF

# Retry apt-get with exponential backoff (infinite retry, 10 min max)
apt_retry() {
    local attempt=0
    local delay=30
    local max_delay=600  # 10 minutes max between retries
    
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

apt_retry ufw fail2ban ca-certificates curl iptables-persistent netfilter-persistent

# Fail2Ban
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

# UFW Firewall
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

# Install Docker
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

# iptables for Docker Swarm
iptables -I INPUT 1 -p tcp --dport 2377 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 4789 -j ACCEPT
iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
iptables -A FORWARD -j REJECT --reject-with icmp-host-prohibited
netfilter-persistent save

log "Base setup complete, now joining swarm..."

# Poll manager for swarm join token (infinite retry with 10 min max backoff)
join_swarm() {
    local attempt=0
    local delay=10
    local max_delay=600  # 10 minutes max between retries
    
    while true; do
        attempt=$((attempt + 1))
        log "Fetching swarm join token (attempt $attempt)..."
        
        # Check if already in swarm
        if docker info 2>/dev/null | grep -q "Swarm: active"; then
            log "Already in swarm!"
            return 0
        fi
        
        JOIN_CMD=$(curl -sf --connect-timeout 10 "http://$MANAGER_IP:9999/token" 2>/dev/null || echo "")
        
        if [ -n "$JOIN_CMD" ] && [ "$JOIN_CMD" != "NOT_READY" ]; then
            log "Got join command: $JOIN_CMD"
            if eval "$JOIN_CMD"; then
                log "Successfully joined swarm!"
                return 0
            else
                log "Join command failed, will retry..."
            fi
        else
            log "Manager not ready yet, waiting $${delay}s..."
        fi
        
        sleep $delay
        # Exponential backoff up to max_delay
        delay=$((delay * 2))
        [ $delay -gt $max_delay ] && delay=$max_delay
    done
}

join_swarm

log "Dokploy Worker setup complete!"
touch /opt/dokploy-worker-setup-complete
SETUPEOF

chmod +x /opt/dokploy-worker-setup.sh

# Create systemd service that retries setup until success
cat > /etc/systemd/system/dokploy-worker-setup.service << 'EOF'
[Unit]
Description=Dokploy Worker Initial Setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/opt/dokploy-worker-setup-complete

[Service]
Type=oneshot
ExecStart=/opt/dokploy-worker-setup.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dokploy-worker-setup
systemctl start dokploy-worker-setup
