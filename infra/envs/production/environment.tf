# Tout ce qui distingue cet environnement de l'autre tient dans ce fichier.
# Les autres fichiers de la racine sont identiques dans les deux environnements,
# ce que vérifie un test de cette racine.

terraform {
  # Le bucket, sa région et son point d'accès sont donnés à l'initialisation ;
  # les identifiants S3 viennent de l'environnement et ne sont jamais écrits.
  backend "s3" {
    key          = "production/terraform.tfstate"
    use_lockfile = true

    # Réglages qu'OVHcloud demande pour son stockage compatible S3.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

locals {
  environment = "production"
}

variable "instance_flavor" {
  description = "Gabarit de l'instance."
  type        = string
  default     = "d2-4"
}

variable "private_subnet_cidr" {
  description = "Plage IPv4 du sous-réseau privé de cet environnement. Elle ne se modifie plus après la création : le sous-réseau serait remplacé alors que la base et l'instance y sont rattachées."
  type        = string
  default     = "10.20.0.0/24"
}

variable "private_vlan_id" {
  description = "Identifiant de VLAN du réseau privé, différent pour chaque environnement du projet."
  type        = number
  default     = 20
}
