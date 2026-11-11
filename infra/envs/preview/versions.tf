terraform {
  required_version = "~> 1.13.0"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "= 2.24.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.4.2"
    }
  }

  # L'état et les plans contiennent des secrets : ils sont chiffrés avant de
  # quitter la machine qui les produit. Les noms de ces blocs sont inscrits
  # dans les données chiffrées, il ne faut donc pas les renommer.
  encryption {
    key_provider "pbkdf2" "passphrase" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "passphrase" {
      keys = key_provider.pbkdf2.passphrase
    }

    state {
      method   = method.aes_gcm.passphrase
      enforced = true
    }

    plan {
      method   = method.aes_gcm.passphrase
      enforced = true
    }
  }
}
