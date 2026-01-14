# Local Testing for OCI Cloud-Config Templates

This directory contains testing infrastructure to validate cloud-config templates before deploying to OCI.

## Quick Start

```bash
# Run template validation (fast, no Docker needed)
./test/validate-templates.sh
```

## What Gets Validated

### Structural Validation
- `#cloud-config` header present
- Valid YAML syntax
- Required sections: `packages`, `write_files`, `runcmd`

### Security Validation (Both Manager & Worker)
- Required packages: `ufw`, `fail2ban`, `ca-certificates`, `curl`
- SSH hardening config (`99-dokploy-hardening.conf`)
- Password authentication disabled
- Root login restricted to key-only
- UFW firewall enabled
- Fail2ban configured

### Manager-Specific Validation
- Swarm join script present
- `docker swarm init` command
- Required UFW ports: 3000, 2377, 7946, 4789
- Worker IPs file reference

### Worker-Specific Validation
- No swarm init (workers don't init swarm)
- No swarm-join script (manager handles joining)

### Script Syntax Validation
- Embedded bash scripts checked for syntax errors

## Directory Structure

```
test/
├── validate-templates.sh    # Main validation script
└── docker/                  # Docker-based testing (optional)
    ├── README.md
    ├── Dockerfile.oci-sim
    ├── docker-compose.yml
    ├── entrypoint.sh
    └── test-local.sh
```

## Development Workflow

1. **Edit templates** in `templates/`
2. **Validate**: `./test/validate-templates.sh`
3. **Deploy to OCI** once validation passes

## Docker-Based Testing (Advanced)

The `test/docker/` directory contains Docker-in-Docker infrastructure for more realistic testing. However, this approach has limitations:

- Requires privileged containers
- Docker-in-Docker can fail on remote Docker hosts (boltdb/containerd timeouts)
- Cloud-init datasource detection requires manual setup

For most cases, `validate-templates.sh` is sufficient to catch issues before OCI deployment.

## Sample Output

```
[20:48:50] === Cloud-Config Template Validation ===
[20:48:50] Rendering templates...
  ✓ Templates rendered successfully

[20:48:50] === Structural Validation ===
  ✓ Has #cloud-config header
  ✓ Valid YAML syntax
  ✓ Has 'packages' section
  ...

[20:48:50] === Security Validation ===
  ✓ Package: ufw
  ✓ Package: fail2ban
  ✓ SSH hardening config
  ✓ Password auth disabled
  ...

[20:48:50] === Manager-Specific Validation ===
  ✓ Swarm join script present
  ✓ Swarm init command
  ✓ UFW port 3000
  ...

[20:48:50] === ✓ All validations passed ===
```

## Troubleshooting Common Issues

### YAML Syntax Errors
```bash
# Manually check rendered template
cd test/docker && ./test-local.sh setup
cat rendered/manager-user-data.yml | head -50
```

### Missing Packages
Check `templates/manager_user_data.tpl` and `templates/worker_user_data.tpl` for the `packages:` section.

### Security Config Issues
SSH hardening is in `write_files` section. UFW rules are in `runcmd` section.
