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
  value       = local.admin_password
  sensitive   = true
}

output "dokploy_setup_instructions" {
  description = "Post-deployment instructions"
  value       = <<-EOT
    ============================================
    DOKPLOY DEPLOYMENT COMPLETE
    ============================================
    
    Dashboard: http://${oci_core_instance.dokploy_main.public_ip}:3000/
    Email: ${var.dokploy_admin_email}
    Password: Run 'terraform output -raw dokploy_admin_password' to view
    
    ⚠️  IMPORTANT: Please change your admin password immediately after first login!
       Go to: Dashboard → Settings → Profile → Change Password
    
    Workers will automatically:
    1. Join the Docker Swarm cluster
    2. Register themselves in Dokploy
    3. Add themselves to the cluster
    
    Wait 5-10 minutes for full setup to complete.
    ============================================
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
