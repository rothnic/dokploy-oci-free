output "dokploy_dashboard_url" {
  description = "URL to access the Dokploy dashboard"
  value       = "http://${oci_core_instance.dokploy_main.public_ip}:3000/"
}

output "dokploy_admin_email" {
  description = "Admin email for Dokploy login"
  value       = var.dokploy_admin_email
}

output "dokploy_admin_password" {
  description = "Temporary admin password - CHANGE THIS IMMEDIATELY after first login!"
  value       = nonsensitive(local.admin_password)
  sensitive   = false
}

output "dokploy_setup_instructions" {
  description = "Post-deployment instructions"
  value       = <<-EOT
    ╔═══════════════════════════════════════════════════════════════════╗
    ║                    DOKPLOY DEPLOYMENT COMPLETE                     ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                                                                    ║
    ║  Dashboard: http://${oci_core_instance.dokploy_main.public_ip}:3000/
    ║  Email:     ${var.dokploy_admin_email}
    ║  Password:  ${nonsensitive(local.admin_password)}
    ║                                                                    ║
    ║  ⚠️  SECURITY WARNING:                                            ║
    ║  This is a TEMPORARY password visible in job logs.                ║
    ║  CHANGE IT IMMEDIATELY after first login!                         ║
    ║  Go to: Dashboard → Settings → Profile → Change Password          ║
    ║                                                                    ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                         SETUP STATUS                               ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                                                                    ║
    ║  ⏳ Setup takes 5-10 minutes to complete.                         ║
    ║  The following happens automatically:                              ║
    ║                                                                    ║
    ║  1. Main node installs Docker + Dokploy                            ║
    ║  2. Admin account + API key created                                ║
    ║  3. SSH key pair generated for worker access                       ║
    ║  4. Workers join Docker Swarm cluster                              ║
    ║  5. Workers register in Dokploy via API                            ║
    ║  6. Workers added to cluster                                       ║
    ║                                                                    ║
    ║  Check Dokploy dashboard → Cluster to verify workers.              ║
    ║                                                                    ║
    ╚═══════════════════════════════════════════════════════════════════╝
  EOT
}

output "worker_nodes" {
  description = "Worker node details"
  value = {
    for idx, instance in oci_core_instance.dokploy_worker :
    "worker-${idx + 1}" => {
      public_ip  = instance.public_ip
      private_ip = instance.private_ip
      status     = "Will auto-register in Dokploy"
    }
  }
}
