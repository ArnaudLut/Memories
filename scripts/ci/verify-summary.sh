#!/usr/bin/env bash
#
# verify-summary.sh : écrit le tableau de synthèse du workflow « Vérifier
# l'étape 1 ».
#
# Usage : scripts/ci/verify-summary.sh <rapport du job verify>
#
# Le rapport est le JSON que le job verify écrit sur sa sortie standard. Quand
# le canal de déploiement a échoué, le fichier est vide ou absent, et le
# tableau le dit. Les deux autres contrôles sont jugés sur le résultat de leur
# étape, reçu par l'environnement.
#
# Variables d'environnement obligatoires :
#   LOCK_OUTCOME   résultat de l'étape du verrou (success, failure, cancelled, skipped)
#   PLAN_OUTCOME   résultat de l'étape du plan
#
# Le tableau part dans $GITHUB_STEP_SUMMARY. Ce script ne décide pas du succès
# du workflow : chaque étape de contrôle échoue d'elle-même.

set -euo pipefail

[[ $# -eq 1 && -n ${LOCK_OUTCOME-} && -n ${PLAN_OUTCOME-} ]] || {
  echo "usage : LOCK_OUTCOME=... PLAN_OUTCOME=... verify-summary.sh <rapport du job verify>" >&2
  exit 2
}
report=$1

# row <contrôle> <résultat de l'étape> <détail en cas de succès>
row() {
  case $2 in
    success) printf '| %s | Réussi | %s |\n' "$1" "$3" ;;
    failure) printf '| %s | Échec | Voir le journal de cette étape. |\n' "$1" ;;
    *) printf "| %s | Non exécuté | L'étape n'a pas été lancée. |\n" "$1" ;;
  esac
}

{
  printf "## Vérification de l'étape 1\n\n"
  if jq --exit-status '.checks | type == "object"' "$report" > /dev/null 2>&1; then
    jq --raw-output '
      {
        roles: "Rôles SQL sans privilège excessif",
        pgvector: "Extension pgvector et index HNSW",
        rls: "Cloisonnement par tenant et sauvegarde",
        queue: "Schéma de la file de tâches"
      } as $labels
      | "Environnement \(.env), version `\(.version)`, PostgreSQL \(.postgresql // "inconnu").",
        "",
        "| Contrôle | Résultat | Détail |",
        "| --- | --- | --- |",
        (.checks | to_entries[]
         | "| \($labels[.key] // .key) | \(if .value.status == "ok" then "Réussi" else "Échec" end) | \(.value.detail | gsub("[|\n]"; " ")) |")
    ' "$report"
  else
    printf '| Contrôle | Résultat | Détail |\n| --- | --- | --- |\n'
    printf "| Contrôles de la base | Échec | Aucun rapport n'a été reçu de l'instance : voir le journal de l'étape. |\n"
  fi
  row "Verrou de l'état" "$LOCK_OUTCOME" \
    "Une deuxième écriture conditionnelle est refusée, et l'objet supprimé peut être réécrit."
  row "Plan sans changement" "$PLAN_OUTCOME" \
    "L'infrastructure correspond à sa description."
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
