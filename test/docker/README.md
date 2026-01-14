# Local Docker Testing for OCI Cloud-Config

This directory contains Docker-based infrastructure to test cloud-config templates locally before deploying to OCI.

## Quick Start

```bash
# First-time setup (generates SSH keys, renders templates)
./test-local.sh setup

# Start the simulation (manager + 2 workers)
./test-local.sh start

# Watch logs (cloud-init takes ~2-3 minutes)
./test-local.sh logs

# After ~2-3 minutes, run validation
./test-local.sh test

# Access Dokploy UI
open http://localhost:3000

# SSH into manager
ssh -p 2222 -i ssh-keys/id_rsa root@localhost

# Stop everything
./test-local.sh stop
```

## What This Tests

| Component | OCI Behavior | Docker Simulation |
|-----------|--------------|-------------------|
| cloud-init | Runs at boot | Runs at container start |
| Docker | Native | Docker-in-Docker (DinD) |
| systemd | PID 1 | Runs in privileged container |
| Networking | VCN/Subnet | Docker bridge network |
| SSH | Public IP | Port 2222 on localhost |
| UFW | Native iptables | Works with --privileged |

## Directory Structure

```
test/docker/
├── Dockerfile.oci-sim      # Ubuntu 22.04 + cloud-init + DinD
├── docker-compose.yml      # Manager + 2 workers configuration
├── entrypoint.sh           # Container initialization script
├── test-local.sh           # Main test orchestration script
├── rendered/               # (generated) Rendered cloud-config files
│   ├── manager-user-data.yml
│   └── worker-user-data.yml
└── ssh-keys/               # (generated) Test SSH keypair
    ├── id_rsa
    └── id_rsa.pub
```

## Available Commands

| Command | Description |
|---------|-------------|
| `setup` | Generate SSH keys and render cloud-config templates |
| `start` | Build images and start containers |
| `stop` | Stop containers and remove volumes |
| `logs` | Follow logs from all containers |
| `status` | Show container and swarm status |
| `test` | Run validation tests |
| `shell [container]` | Open bash in container (default: manager) |
| `clean` | Remove all generated files |

## Validation Tests

The `test` command checks:

**Manager:**
- Container running
- Docker daemon operational
- SSH keys installed (root + ubuntu)
- UFW firewall enabled
- Fail2ban running
- SSH hardening config present
- Docker Swarm initialized
- Worker IPs file exists

**Workers:**
- Container running
- Docker daemon operational
- SSH keys installed
- UFW enabled

**Swarm:**
- All 3 nodes joined to swarm

## Debugging

### View cloud-init logs
```bash
docker exec dokploy-manager cat /var/log/cloud-init-output.log
docker exec dokploy-manager cat /var/log/swarm-join-workers.log
```

### Check cloud-init status
```bash
docker exec dokploy-manager cloud-init status --long
```

### Manually re-run swarm join
```bash
docker exec dokploy-manager /usr/local/sbin/swarm-join-workers.sh
```

### Interactive shell
```bash
./test-local.sh shell dokploy-manager
./test-local.sh shell dokploy-worker1
```

## Known Differences from OCI

1. **Network IPs are fixed** - Docker uses 172.28.0.x vs dynamic OCI IPs
2. **No actual Dokploy install** - The upstream script expects a real server
3. **Swarm join uses container IPs** - Manager can SSH to workers at 172.28.0.x

## Iterative Development Workflow

1. Edit templates in `templates/`
2. Re-render: `./test-local.sh setup`
3. Restart: `./test-local.sh stop && ./test-local.sh start`
4. Validate: `./test-local.sh test`
5. Check logs if tests fail: `./test-local.sh logs`
