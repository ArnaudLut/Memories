output "network_id" {
  description = "Identifiant OpenStack régional du réseau privé."
  value       = ovh_cloud_network_private_vrack.this.id
}

output "subnet_id" {
  description = "Identifiant du sous-réseau."
  value       = ovh_cloud_network_private_vrack_subnet.this.id
}
