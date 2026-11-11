terraform {
  required_version = "~> 1.13.0"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "= 2.24.0"
    }
  }

  # Le bucket des états est créé par cette pile : la première application se fait
  # donc avec un état local, grâce à un fichier backend_override.tf temporaire
  # que pose scripts/bootstrap.sh, puis l'état est migré ici.
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    use_lockfile = true

    # Réglages qu'OVHcloud demande pour son stockage compatible S3.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }

  # L'état contient le secret du compte de service et la clé S3 : il est
  # chiffré dès la première application, y compris sur le poste du fondateur.
  # Les noms de ces blocs sont inscrits dans les données chiffrées, il ne faut
  # donc pas les renommer.
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
