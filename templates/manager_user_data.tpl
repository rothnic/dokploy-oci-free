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

  # Orchestrator: ensures manager is set up, then joins workers
  - path: /usr/local/sbin/swarm-join-workers.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      log=/var/log/swarm-join-workers.log
      exec > >(tee -a "$log") 2>&1
      echo "== $(date -Is) starting swarm orchestration =="

      # 1) Run upstream Dokploy script on the manager (unchanged)
      if ! command -v docker >/dev/null 2>&1; then
        echo "Installing Dokploy..."
        curl -fsSL https://dokploy.com/install.sh | sh
      fi

      # 2) Ensure swarm is initialized (script usually does; this is idempotent)
      docker swarm init --advertise-addr "$(curl -4s https://ifconfig.io || hostname -I | awk '{print $1}')" >/dev/null 2>&1 || true

      # 3) Get token + manager public IP (keep consistent with upstream get_ip behavior)
      TOKEN="$(docker swarm join-token -q worker)"
      MGR_PUB="$(curl -4s https://ifconfig.io || hostname -I | awk '{print $1}')"

      # 4) Join each worker (as root), ensuring Docker present and worker not in its own swarm
      FILE="/etc/swarm/workers-public.txt"
      [ -s "$FILE" ] || exit 0

      while read -r WIP; do
        [ -z "$WIP" ] && continue
        echo "Joining worker $WIP ..."
        for i in $(seq 1 18); do
          if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$WIP" \
            "docker version >/dev/null 2>&1 || (curl -fsSL https://dokploy.com/install.sh | sh); \
             docker swarm leave --force >/dev/null 2>&1 || true; \
             docker swarm join --advertise-addr $WIP --token $TOKEN $MGR_PUB:2377"; then
            echo "OK: $WIP"; break
          fi
          echo "  retry $i for $WIP ..."; sleep 10
        done
      done < "$FILE"

      echo "== $(date -Is) swarm orchestration complete =="

  # One-shot unit to run the orchestrator once networking is up
  - path: /etc/systemd/system/swarm-join-workers.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Dokploy manager: auto-join workers to swarm
      After=network.target cloud-init.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/swarm-join-workers.sh
      Restart=on-failure
      RestartSec=15

      [Install]
      WantedBy=multi-user.target

runcmd:
  # Create worker IPs file (avoids YAML injection issues)
  - mkdir -p /etc/swarm
  - |
    cat > /etc/swarm/workers-public.txt << 'WORKER_IPS_EOF'
    ${workers_public_ips}
    WORKER_IPS_EOF

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

  # Start swarm orchestration
  - systemctl daemon-reload
  - systemctl enable --now swarm-join-workers.service