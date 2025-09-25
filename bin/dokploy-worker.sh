#!/bin/bash

# Add ubuntu SSH authorized keys to the root user
mkdir -p /root/.ssh
cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
chown root:root /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Add ubuntu user to sudoers
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# OpenSSH and netfilter-persistent
apt update
apt install -y openssh-server netfilter-persistent
systemctl status sshd

# Permit root login
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Install Docker with retries
echo "Installing Docker with retry logic..."
curl --fail --retry 10 --retry-all-errors -fsSL https://get.docker.com | sh
systemctl enable --now docker

# Wait for Docker to be ready
echo "Waiting for Docker to be ready..."
sleep 10

# Allow Docker Swarm traffic
ufw allow 80,443,3000,996,7946,4789,2377/tcp
ufw allow 7946,4789,2377/udp

iptables -I INPUT 1 -p tcp --dport 2377 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 7946 -j ACCEPT
iptables -I INPUT 1 -p udp --dport 4789 -j ACCEPT

# Save iptables rules (avoid interfering with Docker FORWARD chain)
netfilter-persistent save