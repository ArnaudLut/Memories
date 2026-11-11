data "ovh_cloud_instance_flavors" "catalog" {
  service_name = var.project_id
  region       = var.region
}

data "ovh_cloud_instance_images" "catalog" {
  service_name = var.project_id
  region       = var.region
}

locals {
  flavor_ids = [
    for flavor in data.ovh_cloud_instance_flavors.catalog.flavors :
    flavor.id if flavor.name == var.flavor_name
  ]

  # Seules les images publiques et actives comptent : un instantané du projet
  # qui porterait le même nom ne doit jamais être retenu. La clé commence par
  # la date de création, ce qui classe les images de la plus ancienne à la
  # plus récente.
  images = {
    for image in data.ovh_cloud_instance_images.catalog.images :
    "${image.created_at} ${image.id}" => image.id
    if image.name == var.image_name && upper(image.status) == "ACTIVE" && upper(image.visibility) == "PUBLIC"
  }
  image_ids = reverse(values(local.images))

  ingress = [
    { protocol = "TCP", port = 22, description = "SSH" },
    { protocol = "TCP", port = 80, description = "HTTP" },
    { protocol = "TCP", port = 443, description = "HTTPS" },
    { protocol = "UDP", port = 443, description = "HTTP/3" },
  ]

  # L'interface publique est la seule qui ne porte pas l'identifiant du réseau
  # privé.
  public_ipv4 = flatten([
    for network in try(ovh_cloud_instance.this.current_state.networks, []) : [
      for address in network.addresses : address.ip
      if address.version == 4 && address.type == "FIXED"
    ] if network.id != var.network_id
  ])
}

# Le groupe s'applique à toutes les interfaces. Le trafic sortant reste ouvert
# par la règle qu'OpenStack ajoute à tout nouveau groupe.
resource "ovh_cloud_security_group" "this" {
  service_name = var.project_id
  region       = var.region
  name         = var.name
  description  = "SSH, HTTP et HTTPS depuis Internet"

  rule = [
    for entry in local.ingress : {
      direction        = "INGRESS"
      ethernet_type    = "IPV4"
      protocol         = entry.protocol
      port_range_min   = entry.port
      port_range_max   = entry.port
      remote_ip_prefix = "0.0.0.0/0"
      description      = entry.description
    }
  ]
}

resource "ovh_cloud_instance" "this" {
  service_name = var.project_id
  region       = var.region
  name         = var.name
  flavor_id    = one(local.flavor_ids)
  image_id     = try(local.image_ids[0], null)
  user_data    = base64encode(var.user_data)

  networks = [
    { auto_assign_public_ip = true },
    {
      network_id = var.network_id
      subnet_id  = var.subnet_id
    },
  ]

  security_group_ids = [ovh_cloud_security_group.this.id]

  lifecycle {
    # L'image ne sert qu'à la création. Une image plus récente publiée sous le
    # même nom ne doit pas reconstruire l'instance ni effacer son disque.
    ignore_changes = [image_id]

    precondition {
      condition     = length(local.flavor_ids) == 1
      error_message = "Le gabarit « ${var.flavor_name} » est introuvable dans la région ${var.region} du projet."
    }

    precondition {
      condition     = length(local.image_ids) >= 1
      error_message = "Aucune image publique et active ne porte le nom « ${var.image_name} » dans la région ${var.region}."
    }
  }
}
