variable "project_id" {
  description = "Identifiant du projet Public Cloud qui héberge les deux environnements."
  type        = string
}

variable "dns_zone" {
  description = "Zone DNS hébergée chez OVHcloud, par exemple exemple.fr."
  type        = string
}

variable "hostname" {
  description = "Nom complet du service pour cet environnement. Il doit appartenir à la zone."
  type        = string
}

variable "acme_email" {
  description = "Adresse de contact ACME. Aucune ressource ne s'en sert : Caddy la reçoit du déploiement."
  type        = string
}

variable "admin_ssh_public_keys" {
  description = "Clés publiques SSH des administrateurs. Liste vide : aucun compte d'administration. La modifier réinstalle l'instance."
  type        = list(string)
  default     = []
}

variable "image_repository" {
  description = "Seul dépôt d'images que l'instance accepte de déployer. Le modifier réinstalle l'instance."
  type        = string
  default     = "ghcr.io/arnaudlut/memories"
}

variable "state_passphrase" {
  description = "Phrase de passe qui chiffre l'état et les plans, d'au moins 16 caractères."
  type        = string
  sensitive   = true
}

variable "compute_region" {
  description = "Région OpenStack de l'instance et du réseau privé, à Gravelines."
  type        = string
  default     = "GRA11"
}

variable "instance_image" {
  description = "Nom de l'image publique utilisée à la création de l'instance."
  type        = string
  default     = "Ubuntu 24.04"
}

variable "database_region" {
  description = "Région de la base managée, à Gravelines."
  type        = string
  default     = "GRA"

  # Une base managée ne se rattache qu'à un réseau privé de son propre site :
  # la région de calcul doit commencer par celle de la base (GRA11 pour GRA).
  validation {
    condition     = startswith(var.compute_region, var.database_region)
    error_message = "La région de calcul doit appartenir au même site que la base, par exemple GRA11 pour GRA."
  }
}

variable "database_backup_region" {
  description = "Région qui reçoit la copie des sauvegardes de la base, à Strasbourg."
  type        = string
  default     = "SBG"
}

variable "database_plan" {
  description = "Offre de la base managée. Les modules ne déclarent qu'un nœud."
  type        = string
  default     = "essential"
}

variable "database_flavor" {
  description = "Gabarit du nœud de la base managée."
  type        = string
  default     = "db1-4"
}

variable "database_version" {
  description = "Version majeure de PostgreSQL."
  type        = string
  default     = "17"
}
