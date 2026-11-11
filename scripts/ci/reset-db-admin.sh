#!/usr/bin/env bash
#
# reset-db-admin.sh : réinitialise le mot de passe du compte d'administration
# de la base managée et l'écrit dans un fichier job.env.
#
# Usage : scripts/ci/reset-db-admin.sh <projet> <service de base> <fichier job.env>
#
# OVHcloud ne montre le mot de passe d'avnadmin qu'au moment où il est défini.
# Le job db-bootstrap en a besoin une fois : ce script en fait donc générer un
# nouveau par l'API, juste avant le job, et le remet au canal de déploiement
# dans job.env. Il n'est écrit nulle part ailleurs, et n'est jamais affiché.
#
# Le fichier reçoit DB_ADMIN_USER et DB_ADMIN_PASSWORD, que lit le job
# db-bootstrap. Les variables d'environnement sont celles de ovh-api.sh.

set -euo pipefail
# Locale fixe : la validation du mot de passe porte sur de l'ASCII.
export LC_ALL=C
umask 077

readonly READY_TIMEOUT=180

fail() {
  echo "reset-db-admin.sh : $*" >&2
  exit 1
}

(($# == 3)) || {
  echo "usage : reset-db-admin.sh <projet> <service de base> <fichier job.env>" >&2
  exit 2
}
project=$1 cluster=$2 job_env=$3
[[ $project =~ ^[0-9a-f]{32}$ ]] || fail "l'identifiant du projet est mal formé"
[[ $cluster =~ ^[0-9a-f-]{36}$ ]] || fail "l'identifiant du service de base est mal formé"

api=$(dirname "$0")/ovh-api.sh
users=/cloud/project/$project/database/postgresql/$cluster/user

# Le compte d'administration est celui que la plateforme a créé avec le
# service : l'API le désigne par isAdmin, quel que soit son nom.
ids=$("$api" GET "$users" | jq --raw-output '.[]')
admin=''
for id in $ids; do
  [[ $id =~ ^[0-9a-f-]{36}$ ]] || fail "l'API a renvoyé un identifiant de compte inattendu"
  is_admin=$("$api" GET "$users/$id" | jq --raw-output '.isAdmin')
  if [[ $is_admin == true ]]; then
    admin=$id
    break
  fi
done
[[ -n $admin ]] || fail "le service de base n'a pas de compte d'administration"

reset=$("$api" POST "$users/$admin/credentials/reset")
password=$(jq --raw-output '.password // empty' <<< "$reset")
username=$(jq --raw-output '.username // empty' <<< "$reset")
unset reset
# Le masque est posé avant toute autre sortie. Hors de GitHub Actions, la ligne
# afficherait le mot de passe au lieu de le masquer. Dans une commande de
# workflow, le signe % s'écrit %25.
[[ ${GITHUB_ACTIONS-} != true || -z $password ]] || printf '::add-mask::%s\n' "${password//%/%25}"

# job.env n'admet que des lignes CLÉ=VALEUR en ASCII imprimable.
[[ $password =~ ^[\ -~]+$ && $username =~ ^[A-Za-z0-9_-]+$ ]] \
  || fail "l'API n'a pas renvoyé un compte et un mot de passe exploitables"
printf 'DB_ADMIN_USER=%s\nDB_ADMIN_PASSWORD=%s\n' "$username" "$password" > "$job_env"

# La réinitialisation est asynchrone : le job ne doit partir qu'une fois le
# nouveau mot de passe en vigueur.
deadline=$((SECONDS + READY_TIMEOUT))
until status=$("$api" GET "$users/$admin" | jq --raw-output '.status') && [[ $status == READY ]]; do
  ((SECONDS < deadline)) \
    || fail "le compte $username n'est pas prêt après $READY_TIMEOUT secondes (état : ${status:-inconnu})"
  sleep 5
done
echo "reset-db-admin.sh : le mot de passe du compte $username est réinitialisé" >&2
