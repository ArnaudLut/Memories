resource "ovh_cloud_network_private_vrack" "this" {
  service_name = var.project_id
  region       = var.region
  name         = var.name

  # Le VLAN est imposé : sans lui l'API en attribue un, et le modifier ensuite
  # recrée le réseau.
  vlan_id = var.vlan_id
}

resource "ovh_cloud_network_private_vrack_subnet" "this" {
  service_name = var.project_id
  network_id   = ovh_cloud_network_private_vrack.this.id
  region       = var.region
  name         = var.name
  cidr         = var.cidr
  dhcp_enabled = true

  # Aucune passerelle n'est déclarée : la route par défaut de l'instance reste
  # celle de son interface publique. Le résolveur est celui que l'API ajoute
  # d'elle-même ; l'écrire évite un écart entre la configuration et l'état.
  dns_nameservers = ["213.186.33.99"]
}
