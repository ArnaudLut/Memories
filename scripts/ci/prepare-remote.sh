#!/usr/bin/env bash
#
# prepare-remote.sh : prépare, à partir des sorties d'OpenTofu, ce que
# scripts/ci/remote.sh envoie à l'instance.
#
# Usage :
#   tofu -chdir=infra/envs/<environnement> output -json \
#     | scripts/ci/prepare-remote.sh <environnement> <répertoire>
#
# Le script écrit dans le répertoire, réservé à son propriétaire :
#   app.env      environnement de l'application, installé sur l'instance dans
#                /etc/memoire/app.env
#   db-ca.pem    autorité qui signe le certificat de la base
#   deploy-key   clé privée du canal de déploiement
# Il ajoute ensuite à $GITHUB_ENV les variables que lit remote.sh (REMOTE_HOST,
# REMOTE_HOST_KEY, REMOTE_USER, REMOTE_SSH_KEY_FILE, APP_ENV_FILE, DB_CA_FILE)
# et DATABASE_CLUSTER_ID, l'identifiant du service de base. Hors de GitHub
# Actions, ces lignes partent sur la sortie standard.
#
# Les sorties sensibles, c'est-à-dire les mots de passe des rôles SQL et la clé
# privée, sont masquées dans les journaux avant toute écriture. Aucune valeur
# n'est affichée.
#
# Variable d'environnement obligatoire :
#   ACME_EMAIL   adresse de contact du compte ACME, que Caddy reçoit par app.env

set -euo pipefail
export LC_ALL=C
umask 077

fail() {
  echo "prepare-remote.sh : $*" >&2
  exit 1
}

[[ $# -eq 2 && $1 =~ ^(preview|production)$ ]] || {
  echo "usage : tofu output -json | prepare-remote.sh <preview|production> <répertoire>" >&2
  exit 2
}
environment=$1
[[ -n ${ACME_EMAIL-} ]] || fail "la variable ACME_EMAIL est obligatoire"

outputs=$(cat)

# Les messages d'erreur de jq peuvent citer la valeur fautive : ils ne sont
# jamais affichés.
query() { jq --raw-output "$@" <<< "$outputs" 2> /dev/null; }

missing=$(query '
  ["instance_ipv4", "ssh_host_public_key", "deploy_ssh_user", "deploy_ssh_private_key",
   "public_hostname", "database", "database_ca_pem", "database_role_passwords"]
  - keys | join(", ")') || fail "les sorties d'OpenTofu sont illisibles"
[[ -z $missing ]] \
  || fail "sorties absentes de l'état : $missing. L'environnement $environment a-t-il été appliqué ?"

# 1. Masquer les sorties sensibles, ligne par ligne pour la clé. Hors de GitHub
#    Actions, ces lignes afficheraient les secrets au lieu de les masquer.
if [[ ${GITHUB_ACTIONS-} == true ]]; then
  secrets=$(query '.database_role_passwords.value[], .deploy_ssh_private_key.value') \
    || fail "les sorties sensibles sont illisibles"
  while IFS= read -r line; do
    # Les lignes d'en-tête de la clé ne sont pas secrètes. Dans une commande de
    # workflow, le signe % s'écrit %25.
    [[ -z $line || $line == -----* ]] || printf '::add-mask::%s\n' "${line//%/%25}"
  done <<< "$secrets"
  unset secrets
fi

mkdir -p "$2"
chmod 700 "$2"
dir=$(cd "$2" && pwd)

# 2. app.env. APP_VERSION n'y figure pas : l'image la porte déjà. Les « $ » du
#    filtre désignent des variables de jq, pas du shell.
# shellcheck disable=SC2016
query --arg environment "$environment" --arg acme_email "$ACME_EMAIL" '
  "APP_ENV=\($environment)",
  "PUBLIC_HOSTNAME=\(.public_hostname.value)",
  "ACME_EMAIL=\($acme_email)",
  "PGHOST=\(.database.value.host)",
  "PGPORT=\(.database.value.port)",
  "PGDATABASE=\(.database.value.name)",
  "PGSSLMODE=verify-full",
  "PGSSLROOTCERT=/etc/memoire/db-ca.pem",
  (.database_role_passwords.value | to_entries[]
   | "DB_\(.key | ascii_upcase)_PASSWORD=\(.value)")' > "$dir/app.env" \
  || fail "app.env n'a pas pu être écrit"
# L'instance refuse un fichier qui contient autre chose que de l'ASCII
# imprimable : mieux vaut s'en apercevoir ici.
[[ $(tr -d '\n -~' < "$dir/app.env" | wc -c) -eq 0 ]] \
  || fail "une valeur de app.env contient un caractère hors de l'ASCII imprimable"

# 3. Certificat et clé, terminés par un seul saut de ligne.
query '.database_ca_pem.value | sub("\\s+$"; "")' > "$dir/db-ca.pem" \
  || fail "db-ca.pem n'a pas pu être écrit"
query '.deploy_ssh_private_key.value | sub("\\s+$"; "")' > "$dir/deploy-key" \
  || fail "la clé de déploiement n'a pas pu être écrite"

# 4. Variables du canal pour les étapes suivantes. Une valeur sur plusieurs
#    lignes définirait d'autres variables : le nombre de lignes est vérifié.
# shellcheck disable=SC2016
variables=$(query --arg dir "$dir" '
  "REMOTE_HOST=\(.instance_ipv4.value)",
  "REMOTE_HOST_KEY=\(.ssh_host_public_key.value)",
  "REMOTE_USER=\(.deploy_ssh_user.value)",
  "REMOTE_SSH_KEY_FILE=\($dir)/deploy-key",
  "APP_ENV_FILE=\($dir)/app.env",
  "DB_CA_FILE=\($dir)/db-ca.pem",
  "DATABASE_CLUSTER_ID=\(.database.value.cluster_id)"') \
  || fail "les variables du canal n'ont pas pu être calculées"
[[ $(wc -l <<< "$variables") -eq 7 ]] || fail "une sortie d'OpenTofu tient sur plusieurs lignes"
printf '%s\n' "$variables" >> "${GITHUB_ENV:-/dev/stdout}"
