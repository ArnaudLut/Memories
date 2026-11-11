locals {
  engine = "postgresql"

  endpoints = [
    for endpoint in ovh_cloud_project_database.this.endpoints :
    endpoint if endpoint.component == local.engine
  ]
}

# Le compte avnadmin et les rôles SQL ne sont pas déclarés ici : le premier fait
# planter le fournisseur 2.24.0, les seconds sont créés en SQL par le travail
# d'amorçage de la base.
resource "ovh_cloud_project_database" "this" {
  service_name = var.project_id
  description  = var.name
  engine       = local.engine
  version      = var.engine_version
  plan         = var.plan
  flavor       = var.flavor

  nodes {
    region     = var.region
    network_id = var.network_id
    subnet_id  = var.subnet_id
  }

  ip_restrictions {
    ip          = var.allowed_cidr
    description = "Adresses internes"
  }

  # La région du service vient en premier, comme dans les exemples d'OVHcloud.
  backup_regions      = [var.region, var.backup_region]
  deletion_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "ovh_cloud_project_database_database" "this" {
  service_name = var.project_id
  engine       = local.engine
  cluster_id   = ovh_cloud_project_database.this.id
  name         = var.database_name

  lifecycle {
    prevent_destroy = true
  }
}

data "ovh_cloud_project_database_certificates" "this" {
  service_name = var.project_id
  engine       = local.engine
  cluster_id   = ovh_cloud_project_database.this.id
}
