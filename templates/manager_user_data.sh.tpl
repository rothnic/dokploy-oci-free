#!/bin/bash
# Dokploy Manager Node Setup
# Uses shell script (not cloud-config) so OCI can inject SSH keys

# Create setup script that retries on failure
cat > /opt/dokploy-setup.sh << 'SETUPEOF'
#!/bin/bash
set -e

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a /var/log/dokploy-setup.log; }

log "Starting Dokploy Manager setup..."

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
        log "apt-get failed, waiting ${delay}s..."
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
ufw allow 9999/tcp
ufw --force enable

# Install Dokploy
curl -sSL https://dokploy.com/install.sh | sh

# iptables for Docker Swarm
iptables -I INPUT 1 -p tcp --dport 2377 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 4789 -j ACCEPT
iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
iptables -A FORWARD -j REJECT --reject-with icmp-host-prohibited
netfilter-persistent save

# Ensure swarm is initialized
docker swarm init 2>/dev/null || true

# Create swarm token server for workers to auto-join
apt_retry netcat-openbsd

PRIVATE_IP=$(hostname -I | awk '{print $1}')
mkdir -p /opt/swarm-token

cat > /opt/swarm-token/serve.sh << 'TOKENEOF'
#!/bin/bash
while true; do
    TOKEN=$(docker swarm join-token worker -q 2>/dev/null)
    IP=$(hostname -I | awk '{print $1}')
    if [ -n "$TOKEN" ]; then
        RESPONSE="docker swarm join --token $TOKEN $IP:2377"
    else
        RESPONSE="NOT_READY"
    fi
    echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n$RESPONSE" | nc -l -p 9999 -q 1 2>/dev/null || sleep 1
done
TOKENEOF
chmod +x /opt/swarm-token/serve.sh

cat > /etc/systemd/system/swarm-token-server.service << 'EOF'
[Unit]
Description=Swarm Join Token Server
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/opt/swarm-token/serve.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable swarm-token-server
systemctl start swarm-token-server

log "Dokploy Manager setup complete!"
touch /opt/dokploy-setup-complete
SETUPEOF

chmod +x /opt/dokploy-setup.sh

# Create systemd service that retries setup until success
cat > /etc/systemd/system/dokploy-setup.service << 'EOF'
[Unit]
Description=Dokploy Initial Setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/opt/dokploy-setup-complete

[Service]
Type=oneshot
ExecStart=/opt/dokploy-setup.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dokploy-setup
systemctl start dokploy-setup
