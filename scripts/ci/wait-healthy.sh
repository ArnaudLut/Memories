#!/usr/bin/env bash
#
# wait-healthy.sh : attend que le service en ligne annonce la version attendue.
#
# Usage : scripts/ci/wait-healthy.sh <URL de /health> <version attendue>
#   scripts/ci/wait-healthy.sh https://preview.memoire.example.com/health <identifiant du commit>
#
# C'est l'essai de bout en bout d'un déploiement : la requête traverse le DNS,
# le certificat TLS et Caddy, ce que le contrôle fait sur l'instance ne couvre
# pas. Au premier déploiement, Caddy doit d'abord obtenir son certificat :
# l'attente dure jusqu'à dix minutes.

set -euo pipefail

readonly TIMEOUT=600

(($# == 2)) || {
  echo "usage : wait-healthy.sh <URL de /health> <version attendue>" >&2
  exit 2
}
url=$1 expected=$2

deadline=$((SECONDS + TIMEOUT))
# En cas d'échec, « response » reçoit le message d'erreur de curl.
until response=$(curl --silent --show-error --fail --max-time 10 "$url" 2>&1) \
  && version=$(jq --raw-output '.version // empty' <<< "$response" 2> /dev/null) \
  && [[ $version == "$expected" ]]; do
  if ((SECONDS >= deadline)); then
    echo "wait-healthy.sh : $url n'annonce pas la version $expected après $TIMEOUT secondes." >&2
    echo "Dernière réponse : $response" >&2
    exit 1
  fi
  sleep 10
done
echo "La version $expected répond sur $url."
