# Dokploy Feature Request: Headless Admin Initialization

## Summary

Allow Dokploy to be initialized with an admin account via environment variables or CLI, enabling fully automated deployments without manual web UI interaction.

## Problem

Currently, Dokploy requires manual interaction with the web UI to create the initial admin account after installation. This prevents fully automated infrastructure-as-code deployments where:

1. The entire stack should be deployable via Terraform/Pulumi/CloudFormation
2. No human intervention should be required post-deployment
3. Credentials should be generated and output programmatically

## Current Workaround

We implemented a workaround using the Dokploy API:

```bash
# 1. Wait for Dokploy to be ready
while ! curl -sf http://localhost:3000 >/dev/null; do sleep 5; done

# 2. Create admin via sign-up API (only works when no admin exists)
curl -X POST "http://localhost:3000/api/auth/sign-up/email" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"SecurePass123","name":"Admin","lastName":"User"}'

# 3. Login to get session cookie
curl -X POST "http://localhost:3000/api/auth/sign-in/email" \
  -H "Content-Type: application/json" \
  -c /tmp/cookies.txt \
  -d '{"email":"admin@example.com","password":"SecurePass123"}'

# 4. Fetch organization ID (required for API key creation)
ORG_ID=$(curl -sf "http://localhost:3000/api/trpc/organization.all?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%7D%7D" \
  -b /tmp/cookies.txt | jq -r '.[0].result.data.json[0].id')

# 5. Create API key with organization ID
curl -X POST "http://localhost:3000/api/trpc/user.createApiKey?batch=1" \
  -H "Content-Type: application/json" \
  -b /tmp/cookies.txt \
  -d "{\"0\":{\"json\":{\"name\":\"AutoSetup\",\"metadata\":{\"organizationId\":\"$ORG_ID\"},...}}}"
```

### Issues with this workaround:

1. **Timing sensitivity**: Must wait for Dokploy container to be fully ready
2. **API complexity**: Requires understanding internal tRPC endpoints
3. **Organization ID**: Must fetch org ID before creating API key (extra API call)
4. **Session management**: Must handle cookies for authenticated requests
5. **Fragile**: API structure may change between versions

## Proposed Solution

### Option A: Environment Variables (Preferred)

```yaml
# docker-compose.yml
services:
  dokploy:
    image: dokploy/dokploy:latest
    environment:
      DOKPLOY_ADMIN_EMAIL: "admin@example.com"
      DOKPLOY_ADMIN_PASSWORD: "SecurePassword123"
      DOKPLOY_ADMIN_FIRST_NAME: "Admin"
      DOKPLOY_ADMIN_LAST_NAME: "User"
      DOKPLOY_AUTO_GENERATE_API_KEY: "true"
```

On first startup, if no admin exists and these variables are set, Dokploy would:
1. Create the admin account
2. Optionally generate an API key
3. Write the API key to a file (e.g., `/etc/dokploy/api-key`) or stdout

### Option B: CLI Command

```bash
# Run after container starts
docker exec dokploy dokploy-cli init \
  --admin-email "admin@example.com" \
  --admin-password "SecurePassword123" \
  --generate-api-key \
  --output-file /etc/dokploy/credentials.json
```

### Option C: Init Container / Sidecar Pattern

```yaml
# Init script that runs on first boot
services:
  dokploy-init:
    image: dokploy/dokploy:latest
    command: ["dokploy-init", "--config", "/config/admin.json"]
    volumes:
      - ./admin-config.json:/config/admin.json
```

## Use Cases

1. **Cloud Infrastructure Deployments**: OCI, AWS, GCP, Azure automated deployments
2. **Kubernetes Operators**: GitOps-style deployments with ArgoCD/Flux
3. **CI/CD Pipelines**: Automated test environment provisioning
4. **Multi-tenant SaaS**: Programmatic tenant Dokploy instance creation

## Related Context

This feature request arose from developing [dokploy-oci-free](https://github.com/statickidz/dokploy-oci-free), a Terraform project that deploys Dokploy on Oracle Cloud Infrastructure Free Tier with fully automated setup including:

- Admin account creation
- API key generation
- SSH key distribution
- Worker node registration

The automation works but requires fragile API workarounds that could be eliminated with native headless initialization support.

## Prior Art

Similar features in other platforms:

- **Portainer**: `ADMIN_PASSWORD` environment variable
- **Grafana**: `GF_SECURITY_ADMIN_USER` and `GF_SECURITY_ADMIN_PASSWORD`
- **GitLab**: `GITLAB_ROOT_PASSWORD` and initial access token provisioning
- **Vault**: `vault operator init` with JSON output

## Acceptance Criteria

- [ ] Admin account can be created without web UI interaction
- [ ] API key can be generated programmatically on first startup
- [ ] Credentials can be output to file or stdout for automation scripts
- [ ] Feature is opt-in (doesn't affect existing manual setup flow)
- [ ] Documented in official Dokploy docs
