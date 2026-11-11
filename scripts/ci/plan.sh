#!/usr/bin/env bash
#
# plan.sh : planifie une racine OpenTofu et résume le résultat.
#
# Usage : scripts/ci/plan.sh <racine> [--fail-on-change]
#   scripts/ci/plan.sh infra/envs/preview                     avant une application
#   scripts/ci/plan.sh infra/envs/preview --fail-on-change    recherche d'une dérive
#
# La racine doit être initialisée (scripts/ci/tofu-init.sh). Le plan est
# enregistré, chiffré, dans <racine>/plan.tfplan : « tofu apply » le reprend tel
# quel.
#
# Sans option, un plan qui propose des changements passe par le garde-fou
# infra/policy/check_plan.py, qui refuse la destruction d'une ressource
# protégée. Avec --fail-on-change, aucun changement n'est attendu : le moindre
# écart entre l'infrastructure et sa description est une dérive.
#
# Code de sortie : 0 quand le plan est vide ou accepté ; 1 quand la
# planification échoue, quand le garde-fou refuse le plan, ou quand une dérive
# est constatée.
#
# Le résumé part dans $GITHUB_STEP_SUMMARY et la ligne changes=true ou
# changes=false dans $GITHUB_OUTPUT. OpenTofu n'y écrit aucune valeur sensible.
# La forme JSON du plan, elle, contient les secrets en clair : elle ne vit que
# le temps du garde-fou, dans un répertoire temporaire.

set -euo pipefail
umask 077

(($# == 1)) || [[ $# -eq 2 && $2 == --fail-on-change ]] || {
  echo "usage : plan.sh <racine> [--fail-on-change]" >&2
  exit 2
}
root=$1 mode=${2-}
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
output=${GITHUB_OUTPUT:-/dev/null}

# Le verrou de l'état arbitre entre les workflows : celui qui arrive pendant
# qu'un autre planifie ou applique attend son tour.
#
# OpenTofu tourne en arrière-plan pour que ce script reste à l'écoute des
# signaux. À l'annulation d'un job, GitHub ne prévient que le processus de
# l'étape, c'est-à-dire ce script quand l'étape le lance par « exec » : il
# transmet l'arrêt à OpenTofu, qui relâche le verrou avant de sortir.
#
# Le trap est posé avant le lancement : un signal reçu entre le lancement et
# la lecture du numéro de processus est retenu, puis transmis aussitôt après.
status=0 tofu_pid='' early_stop=''
trap 'if [[ -n $tofu_pid ]]; then kill -s TERM "$tofu_pid" 2> /dev/null || true; else early_stop=yes; fi' INT TERM
tofu -chdir="$root" plan -input=false -lock-timeout=10m -detailed-exitcode -out=plan.tfplan &
tofu_pid=$!
[[ -z $early_stop ]] || kill -s TERM "$tofu_pid" 2> /dev/null || true
wait "$tofu_pid" || status=$?
# Un signal interrompt « wait » avant la fin d'OpenTofu : on l'attend encore.
while ((status > 128)) && kill -s 0 "$tofu_pid" 2> /dev/null; do
  status=0
  wait "$tofu_pid" || status=$?
done
trap - INT TERM
case $status in
  0)
    echo "changes=false" >> "$output"
    printf "### Plan de %s\n\nAucun changement : l'infrastructure correspond à sa description.\n" \
      "$root" >> "$summary"
    exit 0
    ;;
  2) echo "changes=true" >> "$output" ;;
  *) exit 1 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

verdict=0
if [[ -n $mode ]]; then
  verdict=1
  echo "Dérive : l'infrastructure ne correspond pas à sa description. Le plan montre ce qu'une application changerait." \
    > "$tmp/verdict"
else
  tofu -chdir="$root" show -json plan.tfplan > "$tmp/plan.json"
  python3 "$(dirname "$0")/../../infra/policy/check_plan.py" "$tmp/plan.json" > "$tmp/verdict" \
    || verdict=1
  rm -f "$tmp/plan.json"
fi
cat "$tmp/verdict"

{
  printf '### Plan de %s\n\n' "$root"
  # Deux espaces en fin de ligne : Markdown garde alors les sauts de ligne.
  sed 's/$/  /' "$tmp/verdict"
  printf '\n<details>\n<summary>Plan complet</summary>\n\n```text\n'
  tofu -chdir="$root" show -no-color plan.tfplan
  printf '```\n\n</details>\n'
} >> "$summary"
exit "$verdict"
