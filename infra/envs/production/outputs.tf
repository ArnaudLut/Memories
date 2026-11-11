output "instance_ipv4" {
  description = "Adresse IPv4 publique de l'instance."
  value       = module.instance.ipv4
}

output "ssh_host_public_key" {
  description = "Clé publique d'hôte SSH de l'instance, à épingler côté client."
  value       = trimspace(tls_private_key.ssh_host.public_key_openssh)
}

output "deploy_ssh_user" {
  description = "Compte SSH du canal de déploiement."
  value       = "deploy"
}

output "deploy_ssh_private_key" {
  description = "Clé privée du canal de déploiement."
  value       = tls_private_key.deploy.private_key_openssh
  sensitive   = true
}

output "public_hostname" {
  description = "Nom complet du service."
  value       = var.hostname
}

output "database" {
  description = "Coordonnées de la base managée."
  value = {
    host       = module.database.host
    port       = module.database.port
    name       = module.database.name
    cluster_id = module.database.cluster_id
  }
}

output "database_ca_pem" {
  description = "Certificat de l'autorité qui signe le certificat de la base."
  value       = module.database.ca_pem
}

output "database_role_passwords" {
  description = "Mot de passe de chaque rôle SQL."
  value       = { for role, password in random_password.database_role : role => password.result }
  sensitive   = true
}
