#!/usr/bin/env bash
#
# ovh-api.sh : appelle l'API OVHcloud avec le compte de service de la CI.
#
# Usage : scripts/ci/ovh-api.sh <GET|POST> <chemin>
#   scripts/ci/ovh-api.sh GET /cloud/project/<projet>/database/postgresql/<service>/user
#
# Le script demande un jeton d'accès par le flux OAuth2 « client credentials »,
# puis envoie la requête, sans corps. La réponse de l'API part sur la sortie
# standard. Un code HTTP autre que 2xx fait échouer le script, qui n'affiche
# alors que le code et le message d'erreur de l'API.
#
# Variables d'environnement obligatoires :
#   OVH_ENDPOINT        point d'accès de l'API ; seul « ovh-eu » est pris en charge
#   OVH_CLIENT_ID       identifiant du compte de service
#   OVH_CLIENT_SECRET   secret du compte de service
#
# Aucun secret ne figure sur une ligne de commande : jq lit l'identifiant et le
# secret dans l'environnement, et curl reçoit le formulaire puis le jeton sur
# son entrée standard.

set -euo pipefail

# Adresses du guide d'OVHcloud sur les comptes de service, pour l'API
# européenne.
readonly TOKEN_URL=https://www.ovh.com/auth/oauth2/token
readonly API_URL=https://api.eu.ovhcloud.com/v1

fail() {
  echo "ovh-api.sh : $*" >&2
  exit 1
}

[[ $# -eq 2 && $1 =~ ^(GET|POST)$ && $2 == /* ]] || {
  echo "usage : ovh-api.sh <GET|POST> <chemin>" >&2
  exit 2
}
method=$1 path=$2

for name in OVH_ENDPOINT OVH_CLIENT_ID OVH_CLIENT_SECRET; do
  [[ -n ${!name-} ]] || fail "la variable $name est obligatoire"
done
[[ $OVH_ENDPOINT == ovh-eu ]] \
  || fail "OVH_ENDPOINT vaut « $OVH_ENDPOINT » : seul ovh-eu est pris en charge"

# request <libellé> <arguments de curl> : écrit le corps de la réponse sur la
# sortie standard, ou échoue quand le code HTTP n'est pas 2xx.
request() {
  local label=$1 response status body
  shift
  response=$(curl --silent --show-error --max-time 60 --write-out '\n%{http_code}' "$@") \
    || fail "$label : la requête n'a pas abouti"
  status=${response##*$'\n'}
  body=${response%$'\n'*}
  if [[ $status != 2?? ]]; then
    # Seul le message d'erreur est repris, jamais le corps entier.
    fail "$label : code HTTP $status : $(jq --raw-output \
      '.message // .error_description // .error // "aucun message"' <<< "$body" 2> /dev/null \
      || echo "réponse illisible")"
  fi
  printf '%s\n' "$body"
}

form=$(jq --null-input --raw-output '
  "grant_type=client_credentials&scope=all"
  + "&client_id=" + (env.OVH_CLIENT_ID | @uri)
  + "&client_secret=" + (env.OVH_CLIENT_SECRET | @uri)')
token=$(request "demande du jeton" --data @- "$TOKEN_URL" <<< "$form" | jq --raw-output '.access_token // empty')
[[ -n $token ]] || fail "demande du jeton : la réponse ne contient pas de jeton"

# POST sans corps : une longueur nulle est annoncée, sans type de contenu.
data=()
[[ $method == GET ]] || data=(--data '' --header 'content-type:')
request "$method $path" --request "$method" "${data[@]}" \
  --header 'accept: application/json' --header @- "$API_URL$path" <<< "authorization: Bearer $token"
