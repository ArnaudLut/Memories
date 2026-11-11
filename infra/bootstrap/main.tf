# Le point d'accès de l'API et les identifiants personnels du fondateur
# viennent de l'environnement (OVH_ENDPOINT, OVH_APPLICATION_KEY,
# OVH_APPLICATION_SECRET, OVH_CONSUMER_KEY).
provider "ovh" {}

locals {
  # Gravelines. La ressource attend le code en majuscules, l'API S3 en minuscules.
  state_region = "GRA"

  # Les noms de bucket sont globaux : l'identifiant du projet rend celui-ci unique.
  state_bucket = "memoire-state-${var.project_id}"

  # Liste fermée, sans joker : ce que les racines d'environnement appellent,
  # plus la réinitialisation du mot de passe d'un compte de la base. Rien ne
  # permet de commander ou de résilier un service, ni de supprimer le service
  # de base de données ou une base.
  ci_actions = [
    "publicCloudProject:apiovh:instance/get",
    "publicCloudProject:apiovh:instance/create",
    "publicCloudProject:apiovh:instance/edit",
    "publicCloudProject:apiovh:instance/delete",
    "publicCloudProject:apiovh:instance/usePublicIP",
    "publicCloudProject:apiovh:reference/instance/flavor/get",
    "publicCloudProject:apiovh:reference/instance/image/get",

    "publicCloudProject:apiovh:network/get",
    "publicCloudProject:apiovh:network/create",
    "publicCloudProject:apiovh:network/edit",
    "publicCloudProject:apiovh:network/delete",
    "publicCloudProject:apiovh:network/subnet/get",
    "publicCloudProject:apiovh:network/subnet/create",
    "publicCloudProject:apiovh:network/subnet/edit",
    "publicCloudProject:apiovh:network/subnet/delete",
    "publicCloudProject:apiovh:securityGroup/get",
    "publicCloudProject:apiovh:securityGroup/create",
    "publicCloudProject:apiovh:securityGroup/edit",
    "publicCloudProject:apiovh:securityGroup/delete",

    # La lecture des disponibilités ne sert qu'à expliquer un refus de création.
    "publicCloudProject:apiovh:database/availability/get",
    "publicCloudProject:apiovh:database/postgresql/get",
    "publicCloudProject:apiovh:database/postgresql/create",
    "publicCloudProject:apiovh:database/postgresql/edit",
    "publicCloudProject:apiovh:database/postgresql/node/get",
    "publicCloudProject:apiovh:database/postgresql/advancedConfiguration/get",
    "publicCloudProject:apiovh:database/postgresql/certificates/get",
    "publicCloudProject:apiovh:database/postgresql/database/get",
    "publicCloudProject:apiovh:database/postgresql/database/create",
    "publicCloudProject:apiovh:database/postgresql/user/get",
    "publicCloudProject:apiovh:database/postgresql/user/credentials/reset",

    # Le rafraîchissement publie les enregistrements modifiés.
    "dnsZone:apiovh:record/get",
    "dnsZone:apiovh:record/create",
    "dnsZone:apiovh:record/edit",
    "dnsZone:apiovh:record/delete",
    "dnsZone:apiovh:refresh",
  ]
}

# Le projet est créé à la main, pour pouvoir saisir le code du bon d'achat. Il
# n'est que lu ici : l'importer comme ressource donnerait à OpenTofu un chemin
# vers sa résiliation.
data "ovh_cloud_project" "this" {
  service_name = var.project_id
}

data "ovh_domain_zone" "this" {
  name = var.dns_zone
}

resource "ovh_me_api_oauth2_client" "ci" {
  name        = "memoire-ci"
  description = "Compte de service de la CI du projet memoire"
  flow        = "CLIENT_CREDENTIALS"
}

resource "ovh_iam_policy" "ci" {
  name        = "memoire-ci"
  description = "Droits de la CI sur le projet Public Cloud et la zone DNS de memoire"
  identities  = [ovh_me_api_oauth2_client.ci.identity]
  resources   = [data.ovh_cloud_project.this.iam.urn, data.ovh_domain_zone.this.urn]
  allow       = local.ci_actions
}

# Aucun propriétaire n'est désigné : l'utilisateur S3 ci-dessous n'a ainsi sur
# le bucket que les droits de sa politique, et le remplacer ne recrée jamais le
# bucket.
resource "ovh_cloud_storage_object_bucket" "state" {
  service_name = var.project_id
  region       = local.state_region
  name         = local.state_bucket

  versioning = {
    status = "ENABLED"
  }

  encryption = {
    algorithm = "AES256"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "ovh_cloud_project_user" "state" {
  service_name = var.project_id
  description  = "memoire-state"
  role_names   = ["objectstore_operator"]
}

resource "ovh_cloud_project_user_s3_credential" "state" {
  service_name = var.project_id
  user_id      = ovh_cloud_project_user.state.id
}

# Ce qu'il faut au backend s3 et à son verrou, et rien d'autre : lister le
# bucket, lire, écrire et supprimer ses objets.
resource "ovh_cloud_project_user_s3_policy" "state" {
  service_name = var.project_id
  user_id      = ovh_cloud_project_user.state.id

  policy = jsonencode({
    Statement = [
      {
        Sid      = "ListStateBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::${ovh_cloud_storage_object_bucket.state.name}"]
      },
      {
        Sid      = "ReadWriteStateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${ovh_cloud_storage_object_bucket.state.name}/*"]
      },
    ]
  })
}

# Les réseaux privés des environnements passent par le vRack du projet. Les
# projets récents en reçoivent un à leur création ; cette pile n'en commande
# pas. Le contrôle avertit sans bloquer, car il ne conditionne aucune ressource
# créée ici. La source de données n'est pas imbriquée dans le contrôle : elle
# serait alors relue à chaque application et aucun plan ne serait plus vide.
data "ovh_cloud_project_vrack" "this" {
  service_name = var.project_id
}

check "project_vrack" {
  assert {
    # Sans vRack, l'API répond 404 et la source ne renvoie aucun identifiant.
    condition     = try(startswith(data.ovh_cloud_project_vrack.this.id, "pn-"), false)
    error_message = "Le projet ne semble rattaché à aucun vRack : les réseaux privés des environnements ne pourront pas être créés. Voir infra/README.md."
  }
}
