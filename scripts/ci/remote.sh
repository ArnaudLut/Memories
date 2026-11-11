#!/usr/bin/env bash
#
# remote.sh : envoie une requête à l'instance par le canal de déploiement.
#
# Usage :
#   scripts/ci/remote.sh deploy
#   scripts/ci/remote.sh job <migrate|db-bootstrap|verify>
#
# Le script assemble une archive tar (request.env et les fichiers fournis), puis
# l'écrit sur l'entrée standard de « ssh -T deploy@<instance> ». La clé d'hôte
# est épinglée : la connexion échoue si l'instance en présente une autre. Sur
# l'instance, la commande forcée memoire-deploy valide la requête et l'exécute.
#
# Variables d'environnement obligatoires :
#   REMOTE_HOST           adresse de l'instance (sortie instance_ipv4)
#   REMOTE_HOST_KEY       clé publique d'hôte attendue (sortie ssh_host_public_key)
#   REMOTE_SSH_KEY_FILE   fichier de la clé privée de déploiement, lisible par
#                         son seul propriétaire (sortie deploy_ssh_private_key)
#   IMAGE_DIGEST          empreinte de l'image, sha256:<64 chiffres hexadécimaux>
#
# Variables d'environnement facultatives :
#   REMOTE_USER           compte distant (défaut : deploy)
#   REMOTE_PORT           port SSH (défaut : 22)
#   REMOTE_WAIT_SECONDS   attente maximale du canal, utile tant que l'instance
#                         démarre (défaut : 300)
#   APP_ENV_FILE          fichier installé sur l'instance comme /etc/memoire/app.env
#   DB_CA_FILE            fichier installé comme /etc/memoire/db-ca.pem
#   JOB_ENV_FILE          variables réservées au job, jamais conservées
#   REGISTRY_USER         compte du registre d'images
#   REGISTRY_TOKEN        jeton du registre ; exige REGISTRY_USER
#
# Aucun secret n'est affiché. Le jeton et les fichiers ne sont copiés que dans
# un répertoire temporaire, supprimé en sortie.
#
# Sortie standard : celle du job distant, par exemple le rapport de « verify ».
# Les messages de l'instance et de ce script partent sur la sortie d'erreur.
#
# Code de sortie : celui de la commande distante (0 succès ; 10 requête
# invalide ; 11 image introuvable ; 12 base non amorcée ; 13 version en mauvaise
# santé ; 14 job en échec ; 1 instance pas prête), 2 pour un appel incorrect de
# ce script, 255 quand la connexion SSH échoue.
#
# Dépendances : bash, GNU tar et le client OpenSSH.

set -euo pipefail
export LC_ALL=C
umask 077

readonly MAX_BYTES=1048576

log() { printf 'remote.sh : %s\n' "$*" >&2; }

fail() {
  log "$*"
  exit 2
}

usage() { fail "usage : remote.sh deploy | remote.sh job <migrate|db-bootstrap|verify>"; }

case ${1-} in
  deploy) (($# == 1)) || usage ;;
  job) [[ $# -eq 2 && $2 =~ ^(migrate|db-bootstrap|verify)$ ]] || usage ;;
  *) usage ;;
esac
action=$1 job=${2-}

for name in REMOTE_HOST REMOTE_HOST_KEY REMOTE_SSH_KEY_FILE IMAGE_DIGEST; do
  [[ -n ${!name-} ]] || fail "la variable $name est obligatoire"
done
host=$REMOTE_HOST user=${REMOTE_USER:-deploy} port=${REMOTE_PORT:-22}
wait=${REMOTE_WAIT_SECONDS:-300}
read -r key_type key_data _ <<< "$REMOTE_HOST_KEY"

[[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
  || fail "REMOTE_HOST doit être un nom d'hôte ou une adresse IPv4"
[[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "REMOTE_USER est mal formé"
[[ $port =~ ^[0-9]{1,5}$ && $wait =~ ^[0-9]{1,5}$ ]] \
  || fail "REMOTE_PORT et REMOTE_WAIT_SECONDS doivent être des nombres"
[[ $key_type == ssh-ed25519 && $key_data =~ ^[A-Za-z0-9+/]+=*$ ]] \
  || fail "REMOTE_HOST_KEY doit être une clé publique ssh-ed25519"
[[ -f $REMOTE_SSH_KEY_FILE ]] || fail "REMOTE_SSH_KEY_FILE ne désigne pas un fichier"
[[ $IMAGE_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] \
  || fail "IMAGE_DIGEST doit valoir sha256: suivi de 64 chiffres hexadécimaux"
[[ -z ${REGISTRY_TOKEN-} || -n ${REGISTRY_USER-} ]] || fail "REGISTRY_TOKEN exige REGISTRY_USER"
[[ $action == job || -z ${JOB_ENV_FILE-} ]] || fail "JOB_ENV_FILE est réservé aux jobs"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. Assembler la requête : des fichiers ordinaires à la racine de l'archive,
#    seule forme que la commande forcée accepte.
mkdir "$tmp/request"
{
  printf 'ACTION=%s\nIMAGE_DIGEST=%s\n' "$action" "$IMAGE_DIGEST"
  [[ -z $job ]] || printf 'JOB=%s\n' "$job"
  [[ -z ${REGISTRY_USER-} ]] || printf 'REGISTRY_USER=%s\n' "$REGISTRY_USER"
} > "$tmp/request/request.env"
members=(request.env)

# add_member <nom dans l'archive> <variable qui désigne le fichier local>
add_member() {
  [[ -n ${!2-} ]] || return 0
  [[ -f ${!2} ]] || fail "$2 ne désigne pas un fichier"
  cp -- "${!2}" "$tmp/request/$1"
  members+=("$1")
}
add_member app.env APP_ENV_FILE
add_member db-ca.pem DB_CA_FILE
add_member job.env JOB_ENV_FILE
if [[ -n ${REGISTRY_TOKEN-} ]]; then
  printf '%s' "$REGISTRY_TOKEN" > "$tmp/request/registry-token"
  members+=(registry-token)
fi

tar --create --file "$tmp/request.tar" --directory "$tmp/request" \
  --format=ustar --owner=0 --group=0 --numeric-owner --mode=0600 -- "${members[@]}"
(($(stat --format %s "$tmp/request.tar") <= MAX_BYTES)) || fail "l'archive dépasse 1 Mio"

# 2. Épingler la clé d'hôte. La configuration SSH de la machine est ignorée.
if [[ $port == 22 ]]; then
  printf '%s %s %s\n' "$host" "$key_type" "$key_data" > "$tmp/known_hosts"
else
  printf '[%s]:%s %s %s\n' "$host" "$port" "$key_type" "$key_data" > "$tmp/known_hosts"
fi

remote() {
  ssh -T -F /dev/null -p "$port" -i "$REMOTE_SSH_KEY_FILE" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$tmp/known_hosts" \
    -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 \
    -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=4 \
    "$user@$host"
}

# 3. Attendre le canal. Une instance qui démarre n'ouvre pas tout de suite son
#    port SSH. Une requête vide ne change rien sur l'instance : la commande
#    forcée la refuse avec le code 10, ce qui prouve que le canal fonctionne de
#    bout en bout sans que la vraie requête ait été envoyée.
deadline=$((SECONDS + wait))
while true; do
  status=0
  remote < /dev/null > /dev/null 2> "$tmp/probe.err" || status=$?
  ((status != 10)) || break
  if ((SECONDS >= deadline)); then
    cat "$tmp/probe.err" >&2
    log "le canal de déploiement ne répond pas après $wait secondes"
    exit 255
  fi
  sleep 5
done

# 4. Envoyer la requête, une seule fois.
status=0
remote < "$tmp/request.tar" || status=$?
exit "$status"
