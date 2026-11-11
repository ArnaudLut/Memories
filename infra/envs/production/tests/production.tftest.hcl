# Tests joués avec un fournisseur OVHcloud simulé : aucun appel à l'API,
# aucune ressource réelle. La production n'est ni planifiée ni appliquée avant
# la fin de l'étape 2 : ces tests empêchent sa racine de s'écarter de celle de
# la préversion d'ici là.

mock_provider "ovh" {
  mock_data "ovh_cloud_instance_flavors" {
    defaults = {
      flavors = [
        {
          id          = "f0000000-0000-4000-8000-000000000004"
          name        = "d2-4"
          description = null
          disk        = 50
          ephemeral   = 0
          is_public   = true
          location    = { region = "GRA11", availability_zone = null }
          ram         = 4000
          swap        = 0
          vcpus       = 2
        },
      ]
    }
  }

  mock_data "ovh_cloud_instance_images" {
    defaults = {
      images = [
        {
          id         = "a0000000-0000-4000-8000-000000000002"
          name       = "Ubuntu 24.04"
          status     = "ACTIVE"
          visibility = "PUBLIC"
          created_at = "2026-06-02T08:00:00Z"
          updated_at = "2026-06-02T08:00:00Z"
          os_type    = "LINUX"
          min_disk   = 0
          min_ram    = 0
          size       = 1000000000
          location   = { region = "GRA11", availability_zone = null }
        },
      ]
    }
  }

  mock_resource "ovh_cloud_network_private_vrack" {
    defaults = {
      id = "b0000000-0000-4000-8000-000000000002"
    }
  }

  mock_resource "ovh_cloud_network_private_vrack_subnet" {
    defaults = {
      id = "c0000000-0000-4000-8000-000000000002"
    }
  }

  mock_resource "ovh_cloud_project_database" {
    defaults = {
      id = "d0000000-0000-4000-8000-000000000002"
      endpoints = [
        {
          component = "postgresql"
          domain    = "postgresql-exemple.database.cloud.ovh.net"
          path      = ""
          port      = 20184
          scheme    = "postgres"
          ssl       = true
          ssl_mode  = "require"
          uri       = "postgres://postgresql-exemple.database.cloud.ovh.net:20184/defaultdb?sslmode=require"
        },
      ]
    }
  }

  mock_resource "ovh_cloud_instance" {
    defaults = {
      current_state = {
        flavor          = null
        group           = null
        host_id         = null
        image           = null
        location        = { region = "GRA11", availability_zone = null }
        locked          = false
        name            = "memoire-production"
        power_state     = "ACTIVE"
        project_id      = "0123456789abcdef0123456789abcdef"
        security_groups = []
        shares          = []
        ssh_key_name    = null
        user_id         = null
        volumes         = []
        networks = [
          {
            id         = "b0000000-0000-4000-8000-000000000002"
            subnet_id  = "c0000000-0000-4000-8000-000000000002"
            gateway_id = null
            addresses = [
              { ip = "10.20.0.12", mac = "fa:16:3e:00:00:01", type = "FIXED", version = 4 },
            ]
          },
          {
            id         = ""
            subnet_id  = null
            gateway_id = null
            addresses = [
              { ip = "203.0.113.30", mac = "fa:16:3e:00:00:02", type = "FIXED", version = 4 },
            ]
          },
        ]
      }
    }
  }
}

variables {
  project_id       = "0123456789abcdef0123456789abcdef"
  dns_zone         = "example.com"
  hostname         = "memoire.example.com"
  acme_email       = "contact@example.com"
  state_passphrase = "phrase-de-passe-des-essais"
}

run "environment" {
  command = plan

  assert {
    condition     = local.name == "memoire-production"
    error_message = "Les ressources de cet environnement doivent s'appeler memoire-production."
  }

  # Le bloc backend n'est pas lisible depuis un test : la clé est relue dans le
  # fichier, car deux racines sous la même clé partageraient le même état.
  assert {
    condition     = one(flatten(regexall("(?m)^\\s*key\\s*=\\s*\"([^\"]+)\"\\s*(?:(?:#|//).*)?$", file("${path.module}/environment.tf")))) == "production/terraform.tfstate"
    error_message = "L'état de cet environnement doit être rangé sous la clé production/terraform.tfstate."
  }

  # La relecture ci-dessus ne reconnaît pas un commentaire /* */ : une clé qui
  # s'y trouverait passerait pour présente. Tout /* qui n'est pas refermé sur
  # sa ligne est donc refusé, hors des chaînes entre guillemets, qui sont
  # d'abord vidées.
  assert {
    condition     = length(regexall("(?m)/\\*(?:[^*\\n]|\\*+[^*/\\n])*\\**$", replace(file("${path.module}/environment.tf"), "/\"(?:[^\"\\\\\\n]|\\\\.)*\"/", "\"\""))) == 0
    error_message = "environment.tf ne doit contenir aucun /* sans */ sur la même ligne : le contenu d'un commentaire étalé sur plusieurs lignes serait pris pour du code."
  }

  assert {
    condition     = var.instance_flavor == "d2-4" && var.private_subnet_cidr == "10.20.0.0/24" && var.private_vlan_id == 20
    error_message = "Le gabarit, le sous-réseau et le VLAN par défaut doivent être ceux de la production."
  }

  assert {
    condition     = output.instance_ipv4 == "203.0.113.30"
    error_message = "L'adresse publiée doit être l'IPv4 de l'interface publique."
  }

  assert {
    condition = output.database == {
      host       = "postgresql-exemple.database.cloud.ovh.net"
      port       = 20184
      name       = "memoire"
      cluster_id = "d0000000-0000-4000-8000-000000000002"
    }
    error_message = "La sortie database doit décrire le point d'accès du composant postgresql."
  }
}

run "same_files_as_preview" {
  command = plan

  assert {
    condition = alltrue([
      for name in setsubtract(setintersection(fileset(path.module, "*.tf"), fileset("${path.module}/../preview", "*.tf")), ["environment.tf"]) :
      file("${path.module}/${name}") == file("${path.module}/../preview/${name}")
    ])
    error_message = "Tous les fichiers .tf autres qu'environment.tf doivent rester identiques à ceux de la préversion : seul environment.tf distingue les deux racines."
  }

  assert {
    condition     = fileset(path.module, "*.tf") == fileset("${path.module}/../preview", "*.tf")
    error_message = "Les deux racines doivent compter les mêmes fichiers .tf : un fichier présent d'un seul côté les ferait diverger."
  }

  assert {
    condition     = file("${path.module}/.terraform.lock.hcl") == file("${path.module}/../preview/.terraform.lock.hcl")
    error_message = "Les deux racines doivent verrouiller les mêmes versions des fournisseurs : .terraform.lock.hcl diverge de celui de la préversion."
  }
}
