variable "project_id" {
  description = "Identifiant du projet Public Cloud."
  type        = string
}

variable "name" {
  description = "Libellé du service de base de données."
  type        = string
}

variable "region" {
  description = "Région du service au sens des bases managées, par exemple GRA."
  type        = string
}

variable "backup_region" {
  description = "Région qui reçoit la copie des sauvegardes, par exemple SBG."
  type        = string
}

variable "plan" {
  description = "Offre du service. Le module ne déclare qu'un nœud."
  type        = string
}

variable "flavor" {
  description = "Gabarit du nœud, par exemple db1-4."
  type        = string
}

variable "engine_version" {
  description = "Version majeure de PostgreSQL."
  type        = string
}

variable "network_id" {
  description = "Identifiant OpenStack régional du réseau privé."
  type        = string
}

variable "subnet_id" {
  description = "Identifiant du sous-réseau privé."
  type        = string
}

variable "allowed_cidr" {
  description = "Seule plage autorisée à se connecter, sous forme canonique."
  type        = string
}

variable "database_name" {
  description = "Nom de la base créée dans le service."
  type        = string
}
