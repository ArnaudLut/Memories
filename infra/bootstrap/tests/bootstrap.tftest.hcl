# Essais joués avec un fournisseur OVHcloud simulé : aucun appel à l'API,
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
      urn = "urn:v1:eu:resource:dnsZone:exemple.fr"
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
  dns_zone         = "exemple.fr"
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
      "urn:v1:eu:resource:dnsZone:exemple.fr",
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
}

run "state_bucket" {
  command = plan

  assert {
    condition     = ovh_cloud_storage_object_bucket.state.name == "memoire-state-0123456789abcdef0123456789abcdef" && ovh_cloud_storage_object_bucket.state.region == "GRA"
    error_message = "Le bucket d'état doit porter l'identifiant du projet et se trouver à Gravelines."
  }

  assert {
    condition     = ovh_cloud_storage_object_bucket.state.versioning.status == "ENABLED" && ovh_cloud_storage_object_bucket.state.encryption.algorithm == "AES256"
    error_message = "Le bucket d'état doit conserver les versions successives et chiffrer ses objets."
  }

  assert {
    condition     = ovh_cloud_storage_object_bucket.state.owner_user_id == null
    error_message = "Le bucket ne doit pas appartenir à l'utilisateur S3 de la CI."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(ovh_cloud_project_user_s3_policy.state.policy).Statement :
      statement.Effect == "Allow" && alltrue([
        for resource in statement.Resource :
        resource == "arn:aws:s3:::memoire-state-0123456789abcdef0123456789abcdef" || resource == "arn:aws:s3:::memoire-state-0123456789abcdef0123456789abcdef/*"
      ])
    ])
    error_message = "La politique S3 ne doit donner accès qu'au bucket d'état."
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
