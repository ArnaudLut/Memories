#!/usr/bin/env bash
#
# state-lock-test.sh : vérifie que le bucket des états refuse une écriture
# conditionnelle sur un objet qui existe déjà.
#
# Usage : scripts/ci/state-lock-test.sh <clé d'essai>
#   scripts/ci/state-lock-test.sh verify/conditional-write-1234-1
#
# Le verrou de l'état (use_lockfile) repose sur cette propriété : OpenTofu écrit
# l'objet <clé>.tflock avec l'en-tête « If-None-Match: * », et le stockage doit
# refuser la seconde écriture par le code 412. Le script rejoue ce scénario sur
# une clé d'essai, sous le préfixe verify/, sans toucher aux vrais verrous :
#   1. la première écriture conditionnelle réussit ;
#   2. la deuxième est refusée, par l'erreur PreconditionFailed (code 412) ;
#   3. après suppression, l'écriture réussit de nouveau, ce qui prouve qu'un
#      verrou relâché peut être repris alors que le bucket est versionné.
# L'objet d'essai est supprimé en sortie. Sur un bucket versionné, il en reste
# des versions non courantes de quelques octets.
#
# Variables d'environnement obligatoires :
#   STATE_BUCKET, STATE_REGION, STATE_ENDPOINT    sorties de infra/bootstrap
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY      clé S3 du bucket des états
#
# Dépendance : AWS CLI en version 2.

set -euo pipefail

fail() {
  echo "state-lock-test.sh : $*" >&2
  exit 1
}

[[ $# -eq 1 && $1 =~ ^verify/[A-Za-z0-9._-]+$ ]] || {
  echo "usage : state-lock-test.sh verify/<nom de l'objet d'essai>" >&2
  exit 2
}
key=$1

for name in STATE_BUCKET STATE_REGION STATE_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  [[ -n ${!name-} ]] || fail "la variable $name est obligatoire"
done
command -v aws > /dev/null || fail "la commande aws est introuvable"

# Comme le backend d'OpenTofu (skip_s3_checksum), l'essai n'envoie pas les
# sommes de contrôle que l'AWS CLI ajoute par défaut.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

s3api() {
  local operation=$1
  shift
  aws s3api "$operation" --endpoint-url "$STATE_ENDPOINT" --region "$STATE_REGION" \
    --bucket "$STATE_BUCKET" --key "$key" "$@"
}

body=$(mktemp)
created=false
cleanup() {
  rm -f "$body"
  [[ $created == false ]] || s3api delete-object > /dev/null 2>&1 || true
}
trap cleanup EXIT
echo "essai d'écriture conditionnelle" > "$body"

put() { s3api put-object --body "$body" --if-none-match '*'; }

put > /dev/null || fail "la première écriture conditionnelle a échoué"
created=true

if error=$(put 2>&1); then
  fail "la deuxième écriture a été acceptée : le stockage n'applique pas If-None-Match, le verrou de l'état ne protège rien"
elif [[ $error != *PreconditionFailed* && $error != *"(412)"* ]]; then
  fail "la deuxième écriture a échoué pour une autre raison que le code 412 : $error"
fi

s3api delete-object > /dev/null || fail "la suppression de l'objet d'essai a échoué"
created=false
put > /dev/null || fail "après suppression, l'écriture conditionnelle est refusée : un verrou relâché ne pourrait pas être repris"
created=true

echo "Écriture conditionnelle : la deuxième écriture est refusée par le code 412, et l'objet supprimé peut être réécrit."
