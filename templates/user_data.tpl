#cloud-config
package_update: true
packages:
  - ca-certificates
  - curl
  - iptables-persistent
  - netfilter-persistent

write_files:
  - path: /usr/local/sbin/dokploy-install.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      log=/var/log/dokploy-install.log
      exec > >(tee -a "$log") 2>&1
      echo "== $(date -Is) starting dokploy install =="

      # Wait for DNS + egress (handles early boot races)
      for i in {1..30}; do
        if curl -sS https://www.google.com >/dev/null; then break; fi
        echo "network not ready (attempt $i)"
        sleep 5
      done

      curl -fsSL https://get.docker.com | sh
      systemctl enable --now docker
      sysctl -w net.ipv4.ip_forward=1
      curl -fsSL https://dokploy.com/install.sh | sh

      echo "== $(date -Is) dokploy install complete =="

  - path: /etc/systemd/system/dokploy-install.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Install Dokploy after basic network is up
      After=network.target cloud-init.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/dokploy-install.sh
      Restart=on-failure
      RestartSec=10

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl daemon-reload
  - systemctl enable dokploy-install.service
  - systemctl start dokploy-install.service --no-block