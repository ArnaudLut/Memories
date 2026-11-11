output "ipv4" {
  description = "Adresse IPv4 publique de l'instance."
  value       = length(local.public_ipv4) == 1 ? local.public_ipv4[0] : null

  precondition {
    condition     = length(local.public_ipv4) == 1
    error_message = "L'instance devrait porter exactement une adresse IPv4 publique."
  }
}
