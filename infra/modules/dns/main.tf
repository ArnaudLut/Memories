resource "ovh_domain_zone_record" "this" {
  zone      = var.zone
  subdomain = var.hostname == var.zone ? "" : trimsuffix(var.hostname, ".${var.zone}")
  fieldtype = "A"
  target    = var.ipv4

  # La durée est écrite en clair pour que l'état ne dépende pas de la valeur
  # par défaut de la zone. Cinq minutes limitent l'attente si l'adresse change.
  ttl = 300
}
