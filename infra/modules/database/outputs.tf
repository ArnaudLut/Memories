output "host" {
  description = "Nom d'hôte du point d'accès PostgreSQL."
  value       = length(local.endpoints) == 1 ? local.endpoints[0].domain : null

  precondition {
    condition     = length(local.endpoints) == 1
    error_message = "Le service devrait exposer exactement un point d'accès PostgreSQL."
  }
}

output "port" {
  description = "Port du point d'accès PostgreSQL."
  value       = length(local.endpoints) == 1 ? local.endpoints[0].port : null
}

output "name" {
  description = "Nom de la base."
  value       = ovh_cloud_project_database_database.this.name
}

output "cluster_id" {
  description = "Identifiant du service de base de données."
  value       = ovh_cloud_project_database.this.id
}

output "ca_pem" {
  description = "Certificat de l'autorité qui signe le certificat du service."
  value       = data.ovh_cloud_project_database_certificates.this.ca
}
