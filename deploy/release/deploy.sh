#!/bin/bash
#
# deploy.sh : met une version en service, ou lance un job ponctuel.
#
# Ce fichier est livré dans l'image, sous /opt/deploy. La commande forcée
# /usr/local/sbin/memoire-deploy l'en extrait puis le lance en root, après avoir
# chargé l'image et installé la configuration reçue :
#   deploy.sh deploy
#   deploy.sh job <migrate|db-bootstrap|verify>
#
# Variables fournies par la commande forcée :
#   IMAGE          image à lancer, <dépôt>@sha256:<empreinte>
#   RELEASE_DIR    répertoire de cette version, <base>/releases/<empreinte>
#   APP_ENV        environnement de l'instance (preview ou production)
#   APP_ENV_FILE   environnement de l'application, /etc/memoire/app.env
#   DB_CA_FILE     autorité de certification de la base, /etc/memoire/db-ca.pem
#   JOB_ENV_FILE   variables propres au job, quand la requête en apporte
#
# Codes de sortie : 0 succès ; 10 configuration invalide ; 11 image
# inexploitable ; 12 base non amorcée ; 13 nouvelle version en mauvaise santé,
# la précédente est remise en service ; 14 job en échec.
#
# La sortie standard est réservée à celle du job, par exemple le rapport de
# « verify ». Tout le reste part sur la sortie d'erreur.
#
# Pour les tests, COMPOSE_PROJECT_NAME, MEMOIRE_HTTP_PORT et MEMOIRE_HTTPS_PORT
# changent le nom du projet Compose et les ports publiés. En production, sudo
# efface ces variables.

set -euo pipefail
export LC_ALL=C

: "${IMAGE:?}" "${RELEASE_DIR:?}" "${APP_ENV:?}" "${APP_ENV_FILE:?}" "${DB_CA_FILE:?}"
readonly REPOSITORY=${IMAGE%@*}
readonly BASE_DIR=${RELEASE_DIR%/releases/*}
# Délai laissé aux conteneurs d'une version pour devenir sains, en secondes.
readonly WAIT_TIMEOUT=120

log() { printf 'deploy.sh : %s\n' "$*" >&2; }

die() {
  local code=$1
  shift
  log "$*"
  exit "$code"
}

usage() { die 10 "usage : deploy.sh deploy | deploy.sh job <migrate|db-bootstrap|verify>"; }

# Lit une valeur de app.env, sans jamais exécuter ce fichier.
app_setting() { sed --quiet "s/^$1=//p" "$APP_ENV_FILE"; }

# Caddy substitue PUBLIC_HOSTNAME et ACME_EMAIL dans son fichier avant de
# l'analyser : leur forme est vérifiée pour qu'aucune directive ne s'y glisse.
load_site_settings() {
  local hostname='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
  local email='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$'
  PUBLIC_HOSTNAME=$(app_setting PUBLIC_HOSTNAME)
  ACME_EMAIL=$(app_setting ACME_EMAIL)
  [[ $PUBLIC_HOSTNAME =~ $hostname && $ACME_EMAIL =~ $email ]] || return 1
  export PUBLIC_HOSTNAME ACME_EMAIL
}

# compose <répertoire de version> <image> <arguments de docker compose>
compose() {
  local dir=$1 image=$2 ca
  shift 2
  # Empreinte de l'autorité de la base, portée par une étiquette des conteneurs :
  # quand le fichier change, Compose les recrée et ils montent le nouveau.
  ca=$(sha256sum < "$DB_CA_FILE" | cut --delimiter ' ' --fields 1)
  IMAGE=$image DB_CA_SHA256=$ca docker compose --file "$dir/compose.yaml" "$@"
}

# Lance un job dans un conteneur ponctuel. La sortie standard est celle du job.
run_job() {
  local name=$1 status=0
  compose "$RELEASE_DIR" "$IMAGE" run --rm --no-TTY job node apps/jobs/dist/cli.js "$name" \
    || status=$?
  ((status != 0)) || return 0
  [[ $name != migrate || $status -ne 3 ]] \
    || die 12 "la base n'est pas amorcée : lancez le workflow « Amorcer la base », puis relancez le déploiement"
  die 14 "le job $name a échoué avec le code $status"
}

# Version que l'image déclare (ENV APP_VERSION) et que /health doit annoncer.
image_version() {
  docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" \
    | sed --quiet 's/^APP_VERSION=//p'
}

# Version annoncée par /health. La question est posée depuis le conteneur du
# service : au premier déploiement, Caddy n'a pas encore son certificat.
served_version() {
  compose "$RELEASE_DIR" "$IMAGE" exec --no-TTY server node --eval '
    fetch("http://127.0.0.1:8080/health", { signal: AbortSignal.timeout(5000) })
      .then((response) => response.json())
      .then((body) => console.log(body.version));
  '
}

# start <répertoire de version> <image> : démarre une version et attend que
# tous ses conteneurs soient sains.
start() {
  compose "$1" "$2" up --detach --wait --wait-timeout "$WAIT_TIMEOUT" --remove-orphans --quiet-pull >&2
}

# Remplace un lien par renommage : il désigne toujours une version entière.
point() {
  ln --symbolic --force --no-dereference "$2" "$BASE_DIR/$1.new"
  mv --no-target-directory "$BASE_DIR/$1.new" "$BASE_DIR/$1"
}

# Enregistre la version comme version courante. La configuration qui a servi
# est gardée avec elle, pour qu'un retour arrière puisse la remettre en place.
promote() {
  local name=${RELEASE_DIR##*/} current=''
  install --mode 0600 "$APP_ENV_FILE" "$RELEASE_DIR/app.env"
  install --mode 0644 "$DB_CA_FILE" "$RELEASE_DIR/db-ca.pem"
  [[ ! -L $BASE_DIR/current ]] || current=$(readlink "$BASE_DIR/current")
  [[ -z $current || $current == "releases/$name" ]] || point previous "$current"
  point current "releases/$name"
}

# Remet en service la dernière version saine, avec sa configuration. S'il n'y
# en a pas, arrête ce qui a démarré ; les volumes de Caddy sont conservés.
rollback() {
  local dir=$1
  if [[ -z $dir ]]; then
    compose "$RELEASE_DIR" "$IMAGE" down --remove-orphans >&2 || true
  elif install --mode 0600 "$dir/app.env" "$APP_ENV_FILE" \
    && install --mode 0644 "$dir/db-ca.pem" "$DB_CA_FILE" \
    && load_site_settings \
    && start "$dir" "$REPOSITORY@sha256:${dir##*/}"; then
    log "la version précédente est de nouveau en service"
  else
    log "la version précédente n'a pas redémarré : une intervention est nécessaire"
  fi
}

# Ne garde que la version courante et la précédente, images comprises.
prune() {
  local keep=' ' link dir digest
  for link in current previous; do
    [[ ! -L $BASE_DIR/$link ]] || keep+="$(basename "$(readlink "$BASE_DIR/$link")") "
  done
  for dir in "$BASE_DIR"/releases/*/; do
    dir=${dir%/}
    [[ ! -d $dir || $keep == *" ${dir##*/} "* ]] || rm -rf "$dir"
  done
  while read -r digest; do
    [[ $keep == *" ${digest#sha256:} "* ]] \
      || docker image rm "$REPOSITORY@$digest" > /dev/null 2>&1 || true
  done < <(docker image ls --digests --format '{{.Digest}}' "$REPOSITORY")
}

deploy() {
  local expected served='' good=''
  expected=$(image_version)
  [[ -n $expected ]] || die 11 "l'image ne déclare pas APP_VERSION"
  compose "$RELEASE_DIR" "$IMAGE" pull --quiet --policy missing caddy >&2 \
    || die 11 "l'image de Caddy est introuvable"
  run_job migrate >&2

  # Dernière version mise en service avec succès : c'est vers elle qu'on revient.
  [[ ! -d $BASE_DIR/current ]] || good=$(readlink --canonicalize "$BASE_DIR/current")

  if start "$RELEASE_DIR" "$IMAGE" && served=$(served_version) && [[ $served == "$expected" ]]; then
    promote
    prune
    log "la version $expected est en service"
    return
  fi

  log "la nouvelle version n'est pas saine (version attendue : $expected, annoncée : ${served:-aucune})"
  compose "$RELEASE_DIR" "$IMAGE" ps --all >&2 || true
  compose "$RELEASE_DIR" "$IMAGE" logs --no-color --tail 40 >&2 || true
  rollback "$good"
  prune
  exit 13
}

case ${1-} in
  deploy) (($# == 1)) || usage ;;
  job) [[ $# -eq 2 && $2 =~ ^(migrate|db-bootstrap|verify)$ ]] || usage ;;
  *) usage ;;
esac
[[ $RELEASE_DIR == /*/releases/* ]] || die 10 "RELEASE_DIR ne désigne pas un répertoire de version"
[[ -f $APP_ENV_FILE && -f $DB_CA_FILE ]] \
  || die 10 "app.env ou db-ca.pem manque sur l'instance : joignez-les à la requête"
[[ $(app_setting APP_ENV) == "$APP_ENV" ]] \
  || die 10 "app.env ne décrit pas l'environnement « $APP_ENV » de cette instance"
load_site_settings || die 10 "PUBLIC_HOSTNAME ou ACME_EMAIL manque dans app.env, ou est mal formé"

if [[ $1 == deploy ]]; then
  deploy
else
  run_job "$2"
fi
