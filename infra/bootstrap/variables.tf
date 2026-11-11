variable "project_id" {
  description = "Identifiant du projet Public Cloud, créé à la main dans l'espace client."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.project_id))
    error_message = "L'identifiant du projet compte 32 caractères hexadécimaux en minuscules."
  }
}

variable "dns_zone" {
  description = "Zone DNS hébergée chez OVHcloud, par exemple exemple.fr."
  type        = string
}

variable "state_passphrase" {
  description = "Phrase de passe qui chiffre l'état et les plans, d'au moins 16 caractères."
  type        = string
  sensitive   = true
}
