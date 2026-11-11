# Essais joués avec un fournisseur OVHcloud simulé : aucun appel à l'API,
# aucune ressource réelle. Les essais des quatre modules sont rangés ici parce
# que « tofu test » a besoin d'une racine initialisée.

mock_provider "ovh" {
  mock_data "ovh_cloud_instance_flavors" {
    defaults = {
      flavors = [
        {
          id          = "f0000000-0000-4000-8000-000000000002"
          name        = "d2-2"
          description = null
          disk        = 25
          ephemeral   = 0
          is_public   = true
          location    = { region = "GRA11", availability_zone = null }
          ram         = 2000
          swap        = 0
          vcpus       = 1
        },
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

  # Quatre images portent le nom attendu : seule la plus récente des images
  # publiques et actives doit être retenue.
  mock_data "ovh_cloud_instance_images" {
    defaults = {
      images = [
        {
          id         = "a0000000-0000-4000-8000-000000000001"
          name       = "Ubuntu 24.04"
          status     = "ACTIVE"
          visibility = "PUBLIC"
          created_at = "2025-01-10T08:00:00Z"
          updated_at = "2025-01-10T08:00:00Z"
          os_type    = "LINUX"
          min_disk   = 0
          min_ram    = 0
          size       = 1000000000
          location   = { region = "GRA11", availability_zone = null }
        },
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
        {
          id         = "a0000000-0000-4000-8000-000000000003"
          name       = "Ubuntu 24.04"
          status     = "ACTIVE"
          visibility = "PRIVATE"
          created_at = "2026-09-01T08:00:00Z"
          updated_at = "2026-09-01T08:00:00Z"
          os_type    = "LINUX"
          min_disk   = 0
          min_ram    = 0
          size       = 1000000000
          location   = { region = "GRA11", availability_zone = null }
        },
        {
          id         = "a0000000-0000-4000-8000-000000000004"
          name       = "Ubuntu 24.04"
          status     = "DEACTIVATED"
          visibility = "PUBLIC"
          created_at = "2026-10-01T08:00:00Z"
          updated_at = "2026-10-01T08:00:00Z"
          os_type    = "LINUX"
          min_disk   = 0
          min_ram    = 0
          size       = 1000000000
          location   = { region = "GRA11", availability_zone = null }
        },
        {
          id         = "a0000000-0000-4000-8000-000000000005"
          name       = "Debian 12"
          status     = "ACTIVE"
          visibility = "PUBLIC"
          created_at = "2026-10-15T08:00:00Z"
          updated_at = "2026-10-15T08:00:00Z"
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
      id = "b0000000-0000-4000-8000-000000000001"
    }
  }

  mock_resource "ovh_cloud_network_private_vrack_subnet" {
    defaults = {
      id = "c0000000-0000-4000-8000-000000000001"
    }
  }

  mock_resource "ovh_cloud_security_group" {
    defaults = {
      id = "e0000000-0000-4000-8000-000000000001"
    }
  }

  # Deux points d'accès, comme sur un service réel : seul celui du composant
  # postgresql doit être publié.
  mock_resource "ovh_cloud_project_database" {
    defaults = {
      id = "d0000000-0000-4000-8000-000000000001"
      endpoints = [
        {
          component = "postgresqlRead"
          domain    = "postgresql-lecture.database.cloud.ovh.net"
          path      = ""
          port      = 20185
          scheme    = "postgres"
          ssl       = true
          ssl_mode  = "require"
          uri       = "postgres://postgresql-lecture.database.cloud.ovh.net:20185/defaultdb?sslmode=require"
        },
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

  # L'API range l'interface privée et l'interface publique dans la même liste ;
  # l'interface publique porte une IPv6 en plus de son IPv4. Son identifiant de
  # réseau est vide, comme le produit le code du fournisseur 2.24.0.
  mock_resource "ovh_cloud_instance" {
    defaults = {
      current_state = {
        flavor          = null
        group           = null
        host_id         = null
        image           = null
        location        = { region = "GRA11", availability_zone = null }
        locked          = false
        name            = "memoire-preview"
        power_state     = "ACTIVE"
        project_id      = "0123456789abcdef0123456789abcdef"
        security_groups = [{ id = "e0000000-0000-4000-8000-000000000001" }]
        shares          = []
        ssh_key_name    = null
        user_id         = null
        volumes         = []
        networks = [
          {
            id         = "b0000000-0000-4000-8000-000000000001"
            subnet_id  = "c0000000-0000-4000-8000-000000000001"
            gateway_id = null
            addresses = [
              { ip = "10.10.0.12", mac = "fa:16:3e:00:00:01", type = "FIXED", version = 4 },
            ]
          },
          {
            id         = ""
            subnet_id  = null
            gateway_id = null
            addresses = [
              { ip = "2001:db8::10", mac = "fa:16:3e:00:00:02", type = "FIXED", version = 6 },
              { ip = "203.0.113.10", mac = "fa:16:3e:00:00:02", type = "FIXED", version = 4 },
            ]
          },
        ]
      }
    }
  }
}

variables {
  project_id       = "0123456789abcdef0123456789abcdef"
  dns_zone         = "exemple.fr"
  hostname         = "preview.memoire.exemple.fr"
  acme_email       = "contact@exemple.fr"
  state_passphrase = "phrase-de-passe-des-essais"
}

run "environment" {
  command = plan

  assert {
    condition     = local.name == "memoire-preview"
    error_message = "Les ressources de cet environnement doivent s'appeler memoire-preview."
  }

  # Le bloc backend n'est pas lisible depuis un essai : la clé est relue dans le
  # fichier, car deux racines sous la même clé partageraient le même état.
  assert {
    condition     = one(flatten(regexall("key\\s*=\\s*\"([^\"]+)\"", file("${path.module}/environment.tf")))) == "preview/terraform.tfstate"
    error_message = "L'état de cet environnement doit être rangé sous la clé preview/terraform.tfstate."
  }

  assert {
    condition     = var.instance_flavor == "d2-2" && var.private_subnet_cidr == "10.10.0.0/24" && var.private_vlan_id == 10
    error_message = "Le gabarit, le sous-réseau et le VLAN par défaut doivent être ceux de la préversion."
  }

  assert {
    condition     = output.instance_ipv4 == "203.0.113.10"
    error_message = "L'adresse publiée doit être l'IPv4 de l'interface publique."
  }

  assert {
    condition     = output.deploy_ssh_user == "deploy"
    error_message = "Le compte du canal de déploiement doit être deploy."
  }

  assert {
    condition     = output.public_hostname == "preview.memoire.exemple.fr"
    error_message = "Le nom public doit être celui de la variable hostname."
  }

  assert {
    condition = output.database == {
      host       = "postgresql-exemple.database.cloud.ovh.net"
      port       = 20184
      name       = "memoire"
      cluster_id = "d0000000-0000-4000-8000-000000000001"
    }
    error_message = "La sortie database doit décrire le point d'accès du composant postgresql."
  }
}

run "environment_secrets" {
  # Les clés et les mots de passe n'existent qu'après application. La base est
  # remplacée par des sorties fixes : sa protection contre la destruction ferait
  # échouer le nettoyage de fin d'essai.
  override_module {
    target = module.database
    outputs = {
      host       = "postgresql-exemple.database.cloud.ovh.net"
      port       = 20184
      name       = "memoire"
      cluster_id = "d0000000-0000-4000-8000-000000000001"
      ca_pem     = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
    }
  }

  assert {
    condition     = can(regex("^ssh-ed25519 [A-Za-z0-9+/=]+$", output.ssh_host_public_key))
    error_message = "La clé d'hôte doit être une clé ED25519 sur une seule ligne."
  }

  assert {
    condition     = startswith(output.deploy_ssh_private_key, "-----BEGIN OPENSSH PRIVATE KEY-----")
    error_message = "La clé de déploiement doit être fournie au format OpenSSH."
  }

  assert {
    condition     = join(" ", sort(keys(output.database_role_passwords))) == "app auth backup migrator queue"
    error_message = "Il faut un mot de passe pour chacun des cinq rôles SQL."
  }

  assert {
    condition     = alltrue([for password in values(output.database_role_passwords) : can(regex("^[0-9A-Za-z]{40}$", password))])
    error_message = "Chaque mot de passe compte 40 caractères sans caractère spécial."
  }

  assert {
    condition     = startswith(local.user_data, "#cloud-config\n")
    error_message = "Le document cloud-init doit commencer par #cloud-config."
  }

  assert {
    condition     = strcontains(local.user_data, trimspace(tls_private_key.deploy.public_key_openssh))
    error_message = "Le document cloud-init doit porter la clé publique de déploiement."
  }

  assert {
    condition     = strcontains(local.user_data, filebase64("${path.module}/../../../deploy/host/memoire-deploy"))
    error_message = "Le document cloud-init doit embarquer la commande forcée memoire-deploy."
  }
}

run "instance" {
  module {
    source = "../../modules/instance"
  }

  # La documentation du fournisseur annonce un identifiant nul, et non vide,
  # pour l'interface publique : cette forme doit être acceptée elle aussi.
  override_resource {
    target = ovh_cloud_instance.this
    values = {
      current_state = {
        flavor          = null
        group           = null
        host_id         = null
        image           = null
        location        = { region = "GRA11", availability_zone = null }
        locked          = false
        name            = "memoire-essai"
        power_state     = "ACTIVE"
        project_id      = "0123456789abcdef0123456789abcdef"
        security_groups = []
        shares          = []
        ssh_key_name    = null
        user_id         = null
        volumes         = []
        networks = [
          {
            id         = null
            subnet_id  = null
            gateway_id = null
            addresses = [
              { ip = "203.0.113.20", mac = "fa:16:3e:00:00:02", type = "FIXED", version = 4 },
              { ip = "2001:db8::20", mac = "fa:16:3e:00:00:02", type = "FIXED", version = 6 },
            ]
          },
          {
            id         = "b0000000-0000-4000-8000-000000000001"
            subnet_id  = "c0000000-0000-4000-8000-000000000001"
            gateway_id = null
            addresses = [
              { ip = "10.10.0.12", mac = "fa:16:3e:00:00:01", type = "FIXED", version = 4 },
            ]
          },
        ]
      }
    }
  }

  variables {
    region      = "GRA11"
    name        = "memoire-essai"
    flavor_name = "d2-2"
    image_name  = "Ubuntu 24.04"
    network_id  = "b0000000-0000-4000-8000-000000000001"
    subnet_id   = "c0000000-0000-4000-8000-000000000001"
    user_data   = "#cloud-config\n"
  }

  assert {
    condition     = ovh_cloud_instance.this.flavor_id == "f0000000-0000-4000-8000-000000000002"
    error_message = "Le gabarit doit être résolu par son nom."
  }

  assert {
    condition     = ovh_cloud_instance.this.image_id == "a0000000-0000-4000-8000-000000000002"
    error_message = "L'image retenue doit être la plus récente des images publiques et actives."
  }

  assert {
    condition     = ovh_cloud_instance.this.user_data == base64encode("#cloud-config\n")
    error_message = "Le document cloud-init doit être encodé en base64."
  }

  assert {
    condition     = length(ovh_cloud_instance.this.networks) == 2 && ovh_cloud_instance.this.networks[0].auto_assign_public_ip
    error_message = "La première interface doit recevoir une adresse publique."
  }

  assert {
    condition     = ovh_cloud_instance.this.networks[1].network_id == var.network_id && ovh_cloud_instance.this.networks[1].subnet_id == var.subnet_id
    error_message = "La seconde interface doit être celle du réseau privé."
  }

  assert {
    condition     = one(ovh_cloud_instance.this.security_group_ids) == ovh_cloud_security_group.this.id
    error_message = "L'instance ne doit porter que le groupe de sécurité du module."
  }

  assert {
    condition = [for rule in ovh_cloud_security_group.this.rule : "${rule.direction} ${rule.ethernet_type} ${rule.protocol} ${rule.port_range_min}-${rule.port_range_max} ${rule.remote_ip_prefix}"] == [
      "INGRESS IPV4 TCP 22-22 0.0.0.0/0",
      "INGRESS IPV4 TCP 80-80 0.0.0.0/0",
      "INGRESS IPV4 TCP 443-443 0.0.0.0/0",
      "INGRESS IPV4 UDP 443-443 0.0.0.0/0",
    ]
    error_message = "Seuls les ports 22, 80 et 443 doivent être ouverts en entrée."
  }

  assert {
    condition     = output.ipv4 == "203.0.113.20"
    error_message = "L'adresse retenue doit être l'IPv4 de l'interface publique."
  }
}

run "instance_unknown_flavor" {
  command = plan

  module {
    source = "../../modules/instance"
  }

  variables {
    region      = "GRA11"
    name        = "memoire-essai"
    flavor_name = "inexistant"
    image_name  = "Ubuntu 24.04"
    network_id  = "b0000000-0000-4000-8000-000000000001"
    subnet_id   = "c0000000-0000-4000-8000-000000000001"
    user_data   = "#cloud-config\n"
  }

  expect_failures = [ovh_cloud_instance.this]
}

run "instance_unknown_image" {
  command = plan

  module {
    source = "../../modules/instance"
  }

  variables {
    region      = "GRA11"
    name        = "memoire-essai"
    flavor_name = "d2-2"
    image_name  = "Ubuntu 26.04"
    network_id  = "b0000000-0000-4000-8000-000000000001"
    subnet_id   = "c0000000-0000-4000-8000-000000000001"
    user_data   = "#cloud-config\n"
  }

  expect_failures = [ovh_cloud_instance.this]
}

run "instance_user_data_too_large" {
  command = plan

  module {
    source = "../../modules/instance"
  }

  variables {
    region      = "GRA11"
    name        = "memoire-essai"
    flavor_name = "d2-2"
    image_name  = "Ubuntu 24.04"
    network_id  = "b0000000-0000-4000-8000-000000000001"
    subnet_id   = "c0000000-0000-4000-8000-000000000001"
    user_data   = join("", [for index in range(1000) : "01234567890123456789012345678901234567890123456789"])
  }

  expect_failures = [var.user_data]
}

run "network_rejects_untagged_vlan" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    region  = "GRA11"
    name    = "memoire-essai"
    vlan_id = 0
    cidr    = "10.10.0.0/24"
  }

  expect_failures = [var.vlan_id]
}

run "network_rejects_non_canonical_cidr" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    region  = "GRA11"
    name    = "memoire-essai"
    vlan_id = 10
    cidr    = "10.10.0.7/24"
  }

  expect_failures = [var.cidr]
}

run "database" {
  command = plan

  module {
    source = "../../modules/database"
  }

  variables {
    name           = "memoire-essai"
    region         = "GRA"
    backup_region  = "SBG"
    plan           = "essential"
    flavor         = "db1-4"
    engine_version = "17"
    network_id     = "b0000000-0000-4000-8000-000000000001"
    subnet_id      = "c0000000-0000-4000-8000-000000000001"
    allowed_cidr   = "10.10.0.0/24"
    database_name  = "memoire"
  }

  assert {
    condition     = ovh_cloud_project_database.this.deletion_protection
    error_message = "La protection contre la suppression doit être active sur le service."
  }

  assert {
    condition     = ovh_cloud_project_database.this.engine == "postgresql" && ovh_cloud_project_database.this.version == "17"
    error_message = "Le service doit être un PostgreSQL de la version demandée."
  }

  assert {
    condition     = one(ovh_cloud_project_database.this.nodes).region == "GRA"
    error_message = "Le service doit compter un seul nœud, à Gravelines."
  }

  assert {
    condition     = one(ovh_cloud_project_database.this.nodes).network_id == var.network_id && one(ovh_cloud_project_database.this.nodes).subnet_id == var.subnet_id
    error_message = "Le nœud doit être rattaché au réseau privé."
  }

  assert {
    condition     = join(" ", ovh_cloud_project_database.this.backup_regions) == "GRA SBG"
    error_message = "Les sauvegardes doivent rester à Gravelines et être copiées à Strasbourg."
  }

  assert {
    condition     = one(ovh_cloud_project_database.this.ip_restrictions).ip == "10.10.0.0/24"
    error_message = "Seul le sous-réseau privé doit être autorisé à se connecter."
  }

  assert {
    condition     = output.host == "postgresql-exemple.database.cloud.ovh.net" && output.port == 20184
    error_message = "Les sorties doivent décrire le point d'accès du composant postgresql."
  }

  assert {
    condition     = ovh_cloud_project_database_database.this.name == "memoire"
    error_message = "La base doit s'appeler memoire."
  }
}

run "dns_subdomain" {
  command = plan

  module {
    source = "../../modules/dns"
  }

  variables {
    zone     = "exemple.fr"
    hostname = "preview.memoire.exemple.fr"
    ipv4     = "203.0.113.10"
  }

  assert {
    condition     = ovh_domain_zone_record.this.subdomain == "preview.memoire" && ovh_domain_zone_record.this.zone == "exemple.fr"
    error_message = "Le sous-domaine doit être le nom d'hôte privé du suffixe de la zone."
  }

  assert {
    condition     = ovh_domain_zone_record.this.fieldtype == "A" && ovh_domain_zone_record.this.target == "203.0.113.10"
    error_message = "L'enregistrement doit être un A vers l'adresse de l'instance."
  }
}

run "dns_zone_apex" {
  command = plan

  module {
    source = "../../modules/dns"
  }

  variables {
    zone     = "exemple.fr"
    hostname = "exemple.fr"
    ipv4     = "203.0.113.10"
  }

  assert {
    condition     = ovh_domain_zone_record.this.subdomain == ""
    error_message = "Le sommet de la zone s'écrit avec un sous-domaine vide."
  }
}

run "dns_rejects_foreign_hostname" {
  command = plan

  module {
    source = "../../modules/dns"
  }

  variables {
    zone     = "exemple.fr"
    hostname = "memoire.autre-exemple.fr"
    ipv4     = "203.0.113.10"
  }

  expect_failures = [var.hostname]
}
