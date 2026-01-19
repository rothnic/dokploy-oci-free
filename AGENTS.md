# Agent Instructions

## Temporary Files

Place all temporary files in the `tmp/` directory:

- Screenshots
- Logs
- Debug output
- Browser automation artifacts
- Any generated files not meant for commit

```bash
# Example
tmp/screenshot.png
tmp/debug.log
tmp/test-output.json
```

The `tmp/` directory is gitignored and will not be committed.

## Project Overview

Terraform project deploying Dokploy on Oracle Cloud Infrastructure (OCI) Free Tier.

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `bin/` | Helper scripts (`stack.sh` for OCI operations) |
| `doc/` | Documentation and committed screenshots |
| `templates/` | Cloud-init templates for manager/worker nodes |
| `tmp/` | Temporary files (gitignored) |

### Stack Management

Use `bin/stack.sh` for all OCI Resource Manager operations:

```bash
bin/stack.sh apply    # Deploy/update stack
bin/stack.sh destroy  # Tear down stack
bin/stack.sh outputs  # Get IPs and credentials
bin/stack.sh check    # Verify SSH connectivity
```

**Important:** Only committed files are included in `stack apply`. The script uses `git archive HEAD` to create the zip uploaded to OCI. Uncommitted changes will not be deployed.

### Known Issues

See README.md for Dokploy security audit bugs (GitHub #1377).
