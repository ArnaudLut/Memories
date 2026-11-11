# Le point d'accès de l'API et les identifiants du compte de service viennent
# de l'environnement (OVH_ENDPOINT, OVH_CLIENT_ID, OVH_CLIENT_SECRET).
provider "ovh" {}

locals {
  name      = "memoire-${local.environment}"
  sql_roles = ["app", "auth", "queue", "backup", "migrator"]

  # Aucun secret applicatif n'entre dans ce document. Il porte en revanche la
  # clé privée d'hôte SSH, ce qui permet à la CI d'épingler la clé publique.
  user_data = templatefile("${path.module}/../../../deploy/cloud-init.yaml.tftpl", {
    app_env           = local.environment
    image_repository  = var.image_repository
    deploy_public_key = trimspace(tls_private_key.deploy.public_key_openssh)
    admin_public_keys = var.admin_ssh_public_keys
    host_private_key  = tls_private_key.ssh_host.private_key_openssh
    host_public_key   = trimspace(tls_private_key.ssh_host.public_key_openssh)
    deploy_stub_b64   = filebase64("${path.module}/../../../deploy/host/memoire-deploy")
  })
}

# Mots de passe des rôles SQL. Le fournisseur ne crée aucun rôle : ils servent
# au travail d'amorçage de la base, puis au service.
resource "random_password" "database_role" {
  for_each = toset(local.sql_roles)

  length  = 40
  special = false
}

resource "tls_private_key" "deploy" {
  algorithm = "ED25519"
}

resource "tls_private_key" "ssh_host" {
  algorithm = "ED25519"
}

module "network" {
  source = "../../modules/network"

  project_id = var.project_id
  region     = var.compute_region
  name       = local.name
  vlan_id    = var.private_vlan_id
  cidr       = var.private_subnet_cidr
}

module "instance" {
  source = "../../modules/instance"

  project_id  = var.project_id
  region      = var.compute_region
  name        = local.name
  flavor_name = var.instance_flavor
  image_name  = var.instance_image
  network_id  = module.network.network_id
  subnet_id   = module.network.subnet_id
  user_data   = local.user_data
}

module "database" {
  source = "../../modules/database"

  project_id     = var.project_id
  name           = local.name
  region         = var.database_region
  backup_region  = var.database_backup_region
  plan           = var.database_plan
  flavor         = var.database_flavor
  engine_version = var.database_version
  network_id     = module.network.network_id
  subnet_id      = module.network.subnet_id
  allowed_cidr   = var.private_subnet_cidr
  database_name  = "memoire"
}

module "dns" {
  source = "../../modules/dns"

  zone     = var.dns_zone
  hostname = var.hostname
  ipv4     = module.instance.ipv4
}
