# Dokploy Deployment on OCI Free Tier

This Terraform project deploys a **fully automated** Dokploy cluster on Oracle Cloud Infrastructure (OCI) Free Tier. No local tools required - everything is configured via the OCI web console.

## Deploy

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/statickidz/dokploy-oci-free/archive/refs/heads/main.zip)

*Click the button above to deploy directly from GitHub. Configure variables in the web UI, then apply.*

## What Gets Deployed

| Component | Description |
|-----------|-------------|
| **Main Node** | Dokploy dashboard, Docker Swarm leader, Traefik reverse proxy |
| **Worker Nodes** | 1-3 Docker Swarm workers (configurable) |
| **Admin Account** | Pre-configured with your email/password |
| **API Key** | Auto-generated for programmatic access |
| **SSH Keys** | Generated and distributed to all workers |

## Fully Automated Setup

Unlike typical deployments, **everything is automated**:

1. ✅ Dokploy installation
2. ✅ Admin account creation  
3. ✅ API key generation
4. ✅ SSH key generation and distribution
5. ✅ Workers join Docker Swarm
6. ✅ Workers register in Dokploy dashboard

**See [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) for detailed workflow diagrams and implementation details.**

## After Deployment

Your credentials appear in the stack job outputs:

```
Dashboard: http://MAIN_IP:3000/
Email:     your-email@example.com
Password:  TEMPORARY_PASSWORD
```

⚠️ **IMPORTANT**: Change your password immediately after first login!  
Go to: Dashboard → Settings → Profile → Change Password

## About Dokploy

![Dokploy Logo](doc/dokploy-logo.webp)

Dokploy is an open-source deployment tool designed to simplify the management of servers, applications, and databases on your own infrastructure with minimal setup.

For more information, visit [dokploy.com](https://dokploy.com).

![Dokploy Screenshot](doc/dokploy-screenshot.png)

## OCI Free Tier

Oracle Cloud Infrastructure offers a Free Tier with resources ideal for light workloads. The ARM-based VM.Standard.A1.Flex instances provide excellent performance for Dokploy.

For detailed information, visit [OCI Free Tier](https://www.oracle.com/cloud/free/).

**Note**: Free Tier instances are subject to availability. Upgrade to a paid account (keeps free-tier benefits) to remove capacity limitations.

## License

MIT

## Terraform Variables

### Required Variables

| Variable | Description |
|----------|-------------|
| `ssh_authorized_keys` | Your SSH public key for instance access |
| `compartment_id` | OCI compartment ID for deployment |
| `dokploy_admin_email` | Admin email for Dokploy login |

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `dokploy_admin_password` | Auto-generated | Admin password (shown in outputs if auto-generated) |
| `dokploy_admin_first_name` | "Admin" | Admin first name |
| `dokploy_admin_last_name` | "User" | Admin last name |
| `num_worker_instances` | 3 | Number of worker nodes (0-3) |
| `instance_shape` | VM.Standard.A1.Flex | OCI instance shape |
| `memory_in_gbs` | 6 | Memory per instance (GB) |
| `ocpus` | 1 | OCPUs per instance |

## Project Structure

```
├── bin/                  # Helper scripts for local development
├── doc/                  # Documentation and diagrams
│   └── ARCHITECTURE.md   # Detailed workflow documentation
├── templates/            # Cloud-init templates
│   ├── manager_user_data.sh.tpl   # Main node setup
│   └── worker_user_data.sh.tpl    # Worker node setup
├── main.tf               # Core infrastructure
├── variables.tf          # Input variables
├── output.tf             # Stack outputs
└── network.tf            # VCN and security lists
```
