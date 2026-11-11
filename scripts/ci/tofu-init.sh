#!/usr/bin/env bash
#
# tofu-init.sh : initialise une racine OpenTofu avec son état dans le bucket.
#
# Usage : scripts/ci/tofu-init.sh <racine> [options de « tofu init »]
#   scripts/ci/tofu-init.sh infra/envs/preview
#   scripts/ci/tofu-init.sh infra/bootstrap -migrate-state -force-copy
#
# Le bucket, sa région et son point d'accès ne sont pas écrits dans le code :
# ce sont des sorties de infra/bootstrap, reçues ici par l'environnement. Les
# workflows et scripts/bootstrap.sh passent tous par ce script, pour que la
# configuration du backend ne s'écrive qu'à un endroit.
#
# Variables d'environnement obligatoires :
#   STATE_BUCKET, STATE_REGION, STATE_ENDPOINT    sorties de infra/bootstrap
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY      clé S3 du bucket des états
#   TF_VAR_state_passphrase                       phrase de passe de l'état

set -euo pipefail

(($# >= 1)) || {
  echo "usage : tofu-init.sh <racine> [options de tofu init]" >&2
  exit 2
}
root=$1
shift

for name in STATE_BUCKET STATE_REGION STATE_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_VAR_state_passphrase; do
  [[ -n ${!name-} ]] || {
    echo "tofu-init.sh : la variable $name est obligatoire" >&2
    exit 2
  }
done

# Les versions des fournisseurs sont celles du fichier de verrouillage suivi par
# git : l'initialisation échoue plutôt que de le modifier.
exec tofu -chdir="$root" init -input=false -lockfile=readonly \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="region=$STATE_REGION" \
  -backend-config="endpoints={s3=\"$STATE_ENDPOINT\"}" \
  "$@"
