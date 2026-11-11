variable "project_id" {
  description = "Identifiant du projet Public Cloud."
  type        = string
}

variable "region" {
  description = "Région OpenStack du réseau, par exemple GRA11."
  type        = string
}

variable "name" {
  description = "Nom donné au réseau et à son sous-réseau."
  type        = string
}

variable "vlan_id" {
  description = "Identifiant de VLAN dans le vRack du projet, propre à chaque environnement."
  type        = number

  validation {
    condition     = var.vlan_id >= 1 && var.vlan_id <= 4000 && floor(var.vlan_id) == var.vlan_id
    error_message = "L'identifiant de VLAN doit être un entier compris entre 1 et 4000."
  }
}

variable "cidr" {
  description = "Plage IPv4 du sous-réseau sous forme canonique, par exemple 10.10.0.0/24."
  type        = string

  validation {
    condition     = try(cidrsubnet(var.cidr, 0, 0) == var.cidr, false)
    error_message = "La plage doit être écrite sous forme canonique, par exemple 10.10.0.0/24."
  }
}
