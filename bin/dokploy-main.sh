#!/bin/bash
set -euo pipefail
# Add ubuntu SSH authorized keys to the root user
mkdir -p /root/.ssh
cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
chown root:root /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Add ubuntu user to sudoers
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# OpenSSH
apt-get update -y
apt-get install -y openssh-server
systemctl enable --now ssh

# Permit root login
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart ssh

# Installation moved to cloud-init systemd unit triggered after network-online.
# See templates/user_data.tpl

# Swarm/overlay ports; avoid blanket FORWARD REJECT (Docker manages iptables)
ufw allow 80,443,3000,996,7946,4789,2377/tcp || true
ufw allow 7946,4789,2377/udp || true

iptables -I INPUT 1 -p tcp --dport 2377 -j ACCEPT || true
iptables -I INPUT 1 -p udp --dport 7946 -j ACCEPT || true
iptables -I INPUT 1 -p tcp --dport 7946 -j ACCEPT || true
iptables -I INPUT 1 -p udp --dport 4789 -j ACCEPT || true

# Do not add blanket REJECTs to FORWARD; prefer DOCKER-USER if policy needed.

netfilter-persistent save || true