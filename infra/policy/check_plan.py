#!/usr/bin/env python3
"""Garde-fou des plans OpenTofu.

Usage : check_plan.py <plan.json>

Le fichier est la sortie de « tofu show -json <plan> ». Le plan est refusé s'il
supprime ou remplace une ressource protégée : un remplacement détruit lui aussi
la ressource et les données qu'elle porte.

Codes de sortie : 0 si le plan est accepté, 1 s'il est refusé, 2 si le fichier
est absent ou n'est pas un plan lisible.

Le fichier contient des secrets en clair. Ce script n'affiche que des adresses
de ressources, jamais une valeur.
"""

import json
import sys

PROTECTED_TYPES = {
    "ovh_cloud_project": "projet Public Cloud",
    "ovh_cloud_project_database": "service de base de données",
    "ovh_cloud_project_database_database": "base de données",
    "ovh_cloud_storage_object_bucket": "bucket de stockage objet",
}

INSTANCE_TYPE = "ovh_cloud_instance"


class PlanError(Exception):
    """Le fichier fourni n'est pas un plan exploitable."""


def load_resource_changes(path):
    """Renvoie la liste « resource_changes » du plan, ou lève PlanError."""
    try:
        with open(path, encoding="utf-8") as handle:
            plan = json.load(handle)
    except OSError as error:
        raise PlanError(f"lecture impossible ({error.strerror})") from error
    except ValueError as error:
        raise PlanError("le contenu n'est pas du JSON valide") from error

    # Un fichier d'un autre genre, par exemple un état, n'a pas cette liste :
    # mieux vaut s'arrêter que de l'accepter comme un plan sans changement.
    changes = plan.get("resource_changes") if isinstance(plan, dict) else None
    if not isinstance(changes, list):
        raise PlanError("ce n'est pas la sortie de « tofu show -json » pour un plan")

    for change in changes:
        try:
            well_formed = (
                isinstance(change["address"], str)
                and isinstance(change["mode"], str)
                and isinstance(change["type"], str)
                and isinstance(change["change"]["actions"], list)
            )
        except (KeyError, TypeError):
            well_formed = False
        if not well_formed:
            raise PlanError("une entrée de « resource_changes » est incomplète")
    return changes


def destroyed_protected_resources(changes):
    """Renvoie (adresse, libellé, opération) pour chaque destruction interdite."""
    offenders = []
    for change in changes:
        actions = change["change"]["actions"]
        if change["mode"] != "managed" or change["type"] not in PROTECTED_TYPES:
            continue
        # « forget » retire la ressource de l'état sans y toucher : seule
        # l'action « delete », seule ou au sein d'un remplacement, détruit.
        if "delete" not in actions:
            continue
        operation = "remplacement" if "create" in actions else "suppression"
        offenders.append((change["address"], PROTECTED_TYPES[change["type"]], operation))
    return offenders


def reinstalled_instances(changes):
    """Renvoie l'adresse des instances qu'une mise à jour va réinstaller.

    Modifier user_data ne remplace pas l'instance : l'API la réinstalle sur
    place et efface son disque racine, ce que le plan présente comme une simple
    mise à jour d'une valeur masquée.
    """
    addresses = []
    for change in changes:
        details = change["change"]
        if change["mode"] != "managed" or change["type"] != INSTANCE_TYPE:
            continue
        if details["actions"] != ["update"]:
            continue
        before = (details.get("before") or {}).get("user_data")
        after = (details.get("after") or {}).get("user_data")
        unknown = bool((details.get("after_unknown") or {}).get("user_data"))
        # Retirer l'argument (valeur nulle) ne réinstalle pas l'instance.
        if unknown or (after is not None and after != before):
            addresses.append(change["address"])
    return addresses


def main(argv):
    if len(argv) != 2:
        print("Usage : check_plan.py <plan.json>", file=sys.stderr)
        return 2

    try:
        changes = load_resource_changes(argv[1])
    except PlanError as error:
        print(f"check_plan.py : {argv[1]} : {error}.", file=sys.stderr)
        return 2

    for address in reinstalled_instances(changes):
        print(f"Attention : {address} sera réinstallée, car son document cloud-init change. Son disque racine sera effacé.")

    offenders = destroyed_protected_resources(changes)
    if not offenders:
        print("Plan accepté : aucune ressource protégée n'est supprimée ni remplacée.")
        return 0

    if len(offenders) == 1:
        print("Plan refusé : 1 ressource protégée serait détruite.")
    else:
        print(f"Plan refusé : {len(offenders)} ressources protégées seraient détruites.")
    for address, label, operation in offenders:
        print(f"- {address} ({label}) : {operation}")
    print("Ces ressources portent des données qui ne se recréent pas. Une destruction voulue se fait à la main, hors de la CI.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
