#cloud-config
package_update: true
packages:
  - ufw
  - fail2ban
  - ca-certificates
  - curl
  - iptables-persistent
  - netfilter-persistent

write_files:
  # Root key SSH so we can run the upstream script as root (unchanged)
  - path: /root/.ssh/authorized_keys
    permissions: '0600'
    owner: root:root
    content: |
      ${root_authorized_keys}

  # Temporary file for ubuntu SSH keys (will be copied in runcmd)
  - path: /tmp/ubuntu_authorized_keys.txt
    permissions: '0600'
    owner: root:root
    content: |
      ${root_authorized_keys}

  # SSH hardening expected by Dokploy's checks
  - path: /etc/ssh/sshd_config.d/99-dokploy-hardening.conf
    permissions: '0644'
    owner: root:root
    content: |
      PubkeyAuthentication yes
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      ChallengeResponseAuthentication no
      UsePAM no
      PermitRootLogin prohibit-password

  # Fail2Ban: protect SSH aggressively
  - path: /etc/fail2ban/jail.d/sshd.local
    permissions: '0644'
    owner: root:root
    content: |
      [sshd]
      enabled = true
      backend = systemd
      mode = aggressive
      maxretry = 5
      findtime = 10m
      bantime = 1h
      port = ssh

runcmd:
  # Set up ubuntu user SSH keys (must be in runcmd, not write_files, as ubuntu user exists later)
  - mkdir -p /home/ubuntu/.ssh
  - cp /tmp/ubuntu_authorized_keys.txt /home/ubuntu/.ssh/authorized_keys
  - chown -R ubuntu:ubuntu /home/ubuntu/.ssh
  - chmod 700 /home/ubuntu/.ssh
  - chmod 600 /home/ubuntu/.ssh/authorized_keys
  - rm -f /tmp/ubuntu_authorized_keys.txt

  # Apply SSH config
  - systemctl reload ssh || systemctl reload sshd

  # UFW defaults + allows (keeps Security tab green)
  - ufw --force reset
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 22/tcp
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - ufw allow 443/udp
  - ufw allow 3000/tcp
  - ufw allow 2377/tcp
  - ufw allow 7946/tcp
  - ufw allow 7946/udp
  - ufw allow 4789/udp
  - ufw --force enable

  # Fail2Ban on
  - systemctl enable --now fail2ban

  # Run upstream Dokploy script as root
  - curl -fsSL https://dokploy.com/install.sh | sh