# Dokploy OCI Debugging Plan

## Current Status (Jan 14, 2026)

| Component | Status | Notes |
|-----------|--------|-------|
| Template Fix | ✓ APPLIED | Added 6-space indent before `${workers_public_ips}` |
| Terraform Validation | ✓ PASSING | `./test/validate-with-terraform.sh` passes |
| OCI Stack | NEEDS REDEPLOY | Current deployment has broken cloud-config |

## Root Cause (CONFIRMED)

**Terraform's `indent()` function does NOT indent the first line.**

```hcl
indent(6, join("\n", ["IP1", "IP2", "IP3"]))
# Produces:
# IP1          <- NO indent on first line!
#       IP2    <- 6 spaces
#       IP3    <- 6 spaces
```

The template had `${workers_public_ips}` at column 0, so first IP appeared at column 0,
breaking YAML parsing (cloud-init thought it was a new top-level key).

## Fix Applied

In `templates/manager_user_data.tpl`, line 31:
```yaml
# BEFORE (BROKEN)
    content: |
${workers_public_ips}

# AFTER (FIXED)
    content: |
      ${workers_public_ips}
```

The 6 spaces before `${workers_public_ips}` provide the indent for the first line
that `indent(6, ...)` doesn't add.

## Why Previous Tests Missed This

Our test script used pre-formatted strings:
```bash
export workers_public_ips="      172.28.0.11
      172.28.0.12"
```

This pre-baked the indentation for ALL lines, which doesn't match Terraform's actual behavior.

**New test uses actual Terraform** to render templates, catching this class of bugs.

## Validation

```bash
./test/validate-with-terraform.sh
```

This script:
1. Uses real `terraform apply` to render templates with `templatefile()` and `indent()`
2. Validates output YAML with Ruby/Python parsers (same as cloud-init uses)
3. Checks required sections exist

## Deployment Steps

1. Commit and push the fix
2. Download zip from GitHub
3. In OCI Console:
   - Go to Resource Manager > Stacks
   - Select stack `ocid1.ormstack.oc1.iad.amaaaaaapv4hddaaejmlsz6twmxy3ljyop5kpenhduyleexuxcqqc3oobqra`
   - Edit stack, upload new zip
   - Run Destroy (wait for completion)
   - Run Apply
4. Wait 3-5 minutes for Dokploy installation
5. Verify at http://<main-ip>:3000

## Instance Details

- **Main**: 141.148.81.57
- **Workers**: 129.80.75.164, 129.80.228.116, 143.47.99.170
- **Stack OCID**: `ocid1.ormstack.oc1.iad.amaaaaaapv4hddaaejmlsz6twmxy3ljyop5kpenhduyleexuxcqqc3oobqra`

## SSH Access

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@141.148.81.57
```

## Verification Commands (after redeploy)

```bash
# Check cloud-init completed
ssh ubuntu@<ip> 'cloud-init status'

# Check Docker installed
ssh ubuntu@<ip> 'docker --version'

# Check Dokploy running
ssh ubuntu@<ip> 'curl -s localhost:3000 | head -1'
```
