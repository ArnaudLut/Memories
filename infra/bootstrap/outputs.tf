output "ci_client_id" {
  description = "Identifiant du compte de service de la CI."
  value       = ovh_me_api_oauth2_client.ci.client_id
}

output "ci_client_secret" {
  description = "Secret du compte de service de la CI."
  value       = ovh_me_api_oauth2_client.ci.client_secret
  sensitive   = true
}

output "state_bucket" {
  description = "Nom du bucket qui héberge les états."
  value       = ovh_cloud_storage_object_bucket.state.name
}

output "state_region" {
  description = "Région du bucket au sens de l'API S3."
  value       = lower(local.state_region)
}

output "state_endpoint" {
  description = "Point d'accès S3 du bucket."
  value       = "https://s3.${lower(local.state_region)}.io.cloud.ovh.net"
}

output "state_access_key" {
  description = "Clé d'accès S3 limitée au bucket des états."
  value       = ovh_cloud_project_user_s3_credential.state.access_key_id
  sensitive   = true
}

output "state_secret_key" {
  description = "Clé secrète S3 limitée au bucket des états."
  value       = ovh_cloud_project_user_s3_credential.state.secret_access_key
  sensitive   = true
}
