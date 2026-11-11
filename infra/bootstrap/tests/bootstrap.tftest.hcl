# Tests joués avec un fournisseur OVHcloud simulé : aucun appel à l'API,
# aucune ressource réelle. Ils restent en mode plan, car la protection du
# bucket contre la destruction ferait échouer le nettoyage d'une application.

mock_provider "ovh" {
  mock_data "ovh_cloud_project" {
    defaults = {
      iam = {
        id           = "00000000-0000-4000-8000-000000000001"
        display_name = "memoire"
        tags         = {}
        urn          = "urn:v1:eu:resource:publicCloudProject:0123456789abcdef0123456789abcdef"
      }
    }
  }

  mock_data "ovh_domain_zone" {
    defaults = {
      urn = "urn:v1:eu:resource:dnsZone:example.com"
    }
  }

  mock_data "ovh_cloud_project_vrack" {
    defaults = {
      id = "pn-1234567"
    }
  }

  mock_resource "ovh_me_api_oauth2_client" {
    defaults = {
      identity = "urn:v1:eu:identity:credential:xx00000-ovh/oauth2-0123456789abcdef"
    }
  }
}

variables {
  project_id       = "0123456789abcdef0123456789abcdef"
  dns_zone         = "example.com"
  state_passphrase = "phrase-de-passe-des-essais"
}

run "ci_policy" {
  command = plan

  assert {
    condition     = one(ovh_iam_policy.ci.identities) == "urn:v1:eu:identity:credential:xx00000-ovh/oauth2-0123456789abcdef"
    error_message = "La politique ne doit viser que le compte de service de la CI."
  }

  assert {
    condition = join(" ", sort(ovh_iam_policy.ci.resources)) == join(" ", [
      "urn:v1:eu:resource:dnsZone:example.com",
      "urn:v1:eu:resource:publicCloudProject:0123456789abcdef0123456789abcdef",
    ])
    error_message = "La politique ne doit porter que sur le projet et sur la zone DNS."
  }

  # Les familles admises écartent d'emblée la résiliation, les commandes, le
  # vRack, le stockage objet et les utilisateurs du projet, qui permettraient à
  # la CI de s'accorder d'autres droits.
  assert {
    condition = alltrue([
      for action in ovh_iam_policy.ci.allow :
      can(regex("^(publicCloudProject:apiovh:(instance|reference/instance|network|securityGroup|database/availability|database/postgresql)/[A-Za-z/]+|dnsZone:apiovh:(record/[a-z]+|refresh))$", action))
    ])
    error_message = "Chaque action doit être nommée en toutes lettres, sans joker, et rester dans les familles dont les racines d'environnement ont besoin : instance, réseau, groupe de sécurité, base PostgreSQL et enregistrements DNS."
  }

  assert {
    condition = alltrue([
      for action in ovh_iam_policy.ci.allow :
      !can(regex("postgresql/(delete|database/delete|user/(create|edit|delete))$", action))
    ])
    error_message = "La CI ne doit pouvoir supprimer ni le service de base de données ni une base, ni gérer les comptes SQL."
  }

  assert {
    condition     = contains(ovh_iam_policy.ci.allow, "publicCloudProject:apiovh:database/postgresql/user/credentials/reset") && contains(ovh_iam_policy.ci.allow, "dnsZone:apiovh:refresh")
    error_message = "La CI doit pouvoir réinitialiser le mot de passe d'un compte de la base et publier la zone DNS."
  }

  assert {
    condition     = ovh_iam_policy.ci.deny == null && ovh_iam_policy.ci.except == null && ovh_iam_policy.ci.permissions_groups == null
    error_message = "La politique ne doit reposer que sur sa liste d'actions autorisées."
  }

  # La liste entière est comparée : un simple décompte laisserait passer une
  # action remplacée par une autre. BOOTSTRAP.md annonce leur nombre.
  assert {
    condition = join(" ", sort(ovh_iam_policy.ci.allow)) == join(" ", [
      "dnsZone:apiovh:record/create",
      "dnsZone:apiovh:record/delete",
      "dnsZone:apiovh:record/edit",
      "dnsZone:apiovh:record/get",
      "dnsZone:apiovh:refresh",
      "publicCloudProject:apiovh:database/availability/get",
      "publicCloudProject:apiovh:database/postgresql/advancedConfiguration/get",
      "publicCloudProject:apiovh:database/postgresql/certificates/get",
      "publicCloudProject:apiovh:database/postgresql/create",
      "publicCloudProject:apiovh:database/postgresql/database/create",
      "publicCloudProject:apiovh:database/postgresql/database/get",
      "publicCloudProject:apiovh:database/postgresql/edit",
      "publicCloudProject:apiovh:database/postgresql/get",
      "publicCloudProject:apiovh:database/postgresql/node/get",
      "publicCloudProject:apiovh:database/postgresql/user/credentials/reset",
      "publicCloudProject:apiovh:database/postgresql/user/get",
      "publicCloudProject:apiovh:instance/create",
      "publicCloudProject:apiovh:instance/delete",
      "publicCloudProject:apiovh:instance/edit",
      "publicCloudProject:apiovh:instance/get",
      "publicCloudProject:apiovh:instance/usePublicIP",
      "publicCloudProject:apiovh:network/create",
      "publicCloudProject:apiovh:network/delete",
      "publicCloudProject:apiovh:network/edit",
      "publicCloudProject:apiovh:network/get",
      "publicCloudProject:apiovh:network/subnet/create",
      "publicCloudProject:apiovh:network/subnet/delete",
      "publicCloudProject:apiovh:network/subnet/edit",
      "publicCloudProject:apiovh:network/subnet/get",
      "publicCloudProject:apiovh:reference/instance/flavor/get",
      "publicCloudProject:apiovh:reference/instance/image/get",
      "publicCloudProject:apiovh:securityGroup/create",
      "publicCloudProject:apiovh:securityGroup/delete",
      "publicCloudProject:apiovh:securityGroup/edit",
      "publicCloudProject:apiovh:securityGroup/get",
    ])
    error_message = "La liste des actions a changé : toute action ajoutée ou retirée se décide ici, et BOOTSTRAP.md annonce leur nombre, 35."
  }

  assert {
    condition     = ovh_me_api_oauth2_client.ci.flow == "CLIENT_CREDENTIALS"
    error_message = "Le compte de service de la CI doit s'authentifier sans utilisateur."
  }
}

run "state_bucket" {
  command = plan

  assert {
    condition     = ovh_cloud_storage_object_bucket.state.name == "memoire-state-0123456789abcdef0123456789abcdef" && ovh_cloud_storage_object_bucket.state.region == "GRA"
    error_message = "Le bucket des états doit porter l'identifiant du projet et se trouver à Gravelines."
  }

  assert {
    condition     = ovh_cloud_storage_object_bucket.state.versioning.status == "ENABLED" && ovh_cloud_storage_object_bucket.state.encryption.algorithm == "AES256"
    error_message = "Le bucket des états doit conserver les versions successives et chiffrer ses objets."
  }

  assert {
    condition     = ovh_cloud_storage_object_bucket.state.owner_user_id == null
    error_message = "Le bucket ne doit pas appartenir à l'utilisateur S3 de la CI."
  }

  assert {
    condition     = join(" ", ovh_cloud_project_user.state.role_names) == "objectstore_operator"
    error_message = "L'utilisateur S3 ne doit recevoir que le rôle objectstore_operator."
  }

  # La ligne est cherchée dans le bloc du bucket : la même ligne posée sur une
  # autre ressource ne protégerait pas les états.
  assert {
    condition = length(regexall("(?m)^\\s*prevent_destroy\\s*=\\s*true\\s*(?:#.*)?$", one(flatten(regexall(
      "(?s)\\nresource \"ovh_cloud_storage_object_bucket\" \"state\" \\{\\n(.*?)\\n\\}\\n", file("${path.module}/main.tf")
    ))))) == 1
    error_message = "Le bucket des états doit garder prevent_destroy."
  }

  assert {
    condition     = one(flatten(regexall("(?m)^\\s*key\\s*=\\s*\"([^\"]+)\"\\s*(?:#.*)?$", file("${path.module}/versions.tf")))) == "bootstrap/terraform.tfstate"
    error_message = "L'état de cette pile doit être rangé sous la clé bootstrap/terraform.tfstate."
  }

  assert {
    condition     = length(regexall("(?m)^\\s*enforced\\s*=\\s*true\\s*(?:#.*)?$", file("${path.module}/versions.tf"))) == 2
    error_message = "Le chiffrement de l'état et des plans de cette pile doit rester obligatoire : l'état porte le secret du compte de service et la clé S3."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(ovh_cloud_project_user_s3_policy.state.policy).Statement :
      statement.Effect == "Allow" && alltrue([
        for resource in statement.Resource :
        resource == "arn:aws:s3:::memoire-state-0123456789abcdef0123456789abcdef" || resource == "arn:aws:s3:::memoire-state-0123456789abcdef0123456789abcdef/*"
      ])
    ])
    error_message = "La politique S3 ne doit donner accès qu'au bucket des états."
  }

  assert {
    condition = join(" ", sort(flatten([
      for statement in jsondecode(ovh_cloud_project_user_s3_policy.state.policy).Statement : statement.Action
    ]))) == "s3:DeleteObject s3:GetObject s3:ListBucket s3:PutObject"
    error_message = "La politique S3 doit se limiter à ce qu'exigent le backend et son verrou."
  }

  assert {
    condition     = output.state_bucket == "memoire-state-0123456789abcdef0123456789abcdef" && output.state_region == "gra" && output.state_endpoint == "https://s3.gra.io.cloud.ovh.net"
    error_message = "Les sorties doivent décrire le bucket de Gravelines tel que l'attend le backend s3."
  }
}

run "project_without_vrack" {
  command = plan

  # Sans vRack, l'API répond 404 et le fournisseur ne renvoie aucun identifiant.
  override_data {
    target = data.ovh_cloud_project_vrack.this
    values = {
      id = null
    }
  }

  expect_failures = [check.project_vrack]
}

run "rejects_malformed_project_id" {
  command = plan

  variables {
    project_id = "Mon projet"
  }

  expect_failures = [var.project_id]
}
