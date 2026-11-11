variable "zone" {
  description = "Zone DNS hébergée chez OVHcloud, par exemple memoire.example.com."
  type        = string
}

variable "hostname" {
  description = "Nom complet à publier. Il doit appartenir à la zone."
  type        = string

  validation {
    condition     = var.hostname == var.zone || endswith(var.hostname, ".${var.zone}")
    error_message = "Le nom d'hôte doit être la zone DNS elle-même ou l'un de ses sous-domaines."
  }
}

variable "ipv4" {
  description = "Adresse IPv4 vers laquelle pointe le nom."
  type        = string
}
