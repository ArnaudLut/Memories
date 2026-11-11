variable "project_id" {
  description = "Identifiant du projet Public Cloud."
  type        = string
}

variable "region" {
  description = "Région OpenStack de l'instance, par exemple GRA11."
  type        = string
}

variable "name" {
  description = "Nom de l'instance et de son groupe de sécurité."
  type        = string
}

variable "flavor_name" {
  description = "Nom du gabarit dans le catalogue de la région, par exemple d2-2."
  type        = string
}

variable "image_name" {
  description = "Nom de l'image publique dans le catalogue de la région."
  type        = string
}

variable "network_id" {
  description = "Identifiant du réseau privé auquel l'instance est rattachée."
  type        = string
}

variable "subnet_id" {
  description = "Identifiant du sous-réseau privé."
  type        = string
}

variable "user_data" {
  description = "Document cloud-init en clair. Toute modification réinstalle l'instance."
  type        = string
  sensitive   = true

  validation {
    condition     = length(base64encode(var.user_data)) <= 65535
    error_message = "Le document cloud-init dépasse 65535 octets une fois encodé en base64."
  }
}
