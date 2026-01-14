#!/bin/bash
# Dokploy Worker Node Setup
# This uses shell script (not cloud-config) so OCI can inject SSH keys from metadata
set -e

# Wait for cloud-init to finish (it injects SSH keys)
cloud-init status --wait || true

# Copy SSH keys to root (OCI injected them to ubuntu already)
mkdir -p /root/.ssh
cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
chown root:root /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# SSH Hardening (for Dokploy security checks)
cat > /etc/ssh/sshd_config.d/99-dokploy-hardening.conf << 'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin prohibit-password
EOF
systemctl reload ssh || systemctl reload sshd

# Install packages
apt-get update
apt-get install -y ufw fail2ban ca-certificates curl iptables-persistent netfilter-persistent

# Fail2Ban for SSH
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

# Install Docker (prerequisite for swarm worker)
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

# iptables rules for Docker Swarm
iptables -I INPUT 1 -p tcp --dport 2377 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 4789 -j ACCEPT
iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
iptables -A FORWARD -j REJECT --reject-with icmp-host-prohibited
netfilter-persistent save

echo "Dokploy Worker setup complete!"
echo "NOTE: Run 'docker swarm join' command from manager to join this node"
