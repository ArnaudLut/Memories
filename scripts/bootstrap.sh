#!/usr/bin/env bash
#
# bootstrap.sh : amorce le projet OVHcloud et le dépôt GitHub, depuis le poste
# du fondateur. BOOTSTRAP.md décrit ce qui précède et ce qui suit.
#
# Usage :
#   scripts/bootstrap.sh [--project-id <identifiant>] [--dns-zone <zone>]
#                        [--preview-hostname <nom>] [--acme-email <adresse>]
#   scripts/bootstrap.sh rotate
#
# La commande applique infra/bootstrap avec les identifiants personnels du
# fondateur. Elle crée ainsi le compte de service de la CI et sa politique IAM,
# le bucket des états et la clé S3 qui y donne accès. Elle inscrit ensuite dans
# le dépôt GitHub les secrets et les variables que lisent les workflows, puis
# range l'état de cette pile dans le bucket.
#
# « rotate » remplace le compte de service et la clé S3, puis met à jour les
# secrets du dépôt. Aucun workflow ne doit tourner pendant ce temps.
# Si elle s'arrête une fois le renouvellement appliqué, c'est la commande sans
# « rotate » qui reprend : avec « rotate », tout serait renouvelé une seconde fois.
#
# La commande se relance sans risque. Elle travaille toujours sur une copie
# locale de l'état, chiffrée, qu'elle renvoie dans le bucket à la fin : après
# un échec, elle reprend où elle s'était arrêtée, à condition que le fichier
# infra/bootstrap/terraform.tfstate n'ait pas été supprimé.
#
# Variables d'environnement :
#   OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, OVH_CONSUMER_KEY
#       identifiants personnels de l'API OVHcloud, obligatoires.
#   STATE_PASSPHRASE
#       phrase de passe qui chiffre les états. Absente à la toute première
#       exécution, elle est générée et affichée une seule fois. Elle est
#       obligatoire ensuite.
#
# Les valeurs non secrètes viennent des options, à défaut des variables déjà
# inscrites dans le dépôt, à défaut d'une question.
#
# Dépendances : tofu, gh (connecté à GitHub), jq, openssl et curl.

set -euo pipefail
# Locale fixe : les classes de caractères des validations restent de l'ASCII.
export LC_ALL=C
umask 077

readonly ROOT=infra/bootstrap
readonly OVH_API_URL=https://eu.api.ovh.com/1.0

info() { printf '%s\n' "$*" >&2; }

die() {
  info "bootstrap.sh : $*"
  exit 1
}

usage() {
  info "usage : scripts/bootstrap.sh [--project-id <identifiant>] [--dns-zone <zone>] [--preview-hostname <nom>] [--acme-email <adresse>]"
  info "        scripts/bootstrap.sh rotate"
  exit 2
}

# ovh_api <méthode> <chemin> : appelle l'API OVHcloud avec les identifiants
# personnels. La signature suit le guide « Premiers pas avec les API
# OVHcloud » ; les en-têtes passent par l'entrée standard de curl, pas par sa
# ligne de commande.
ovh_api() {
  local method=$1 url=$OVH_API_URL$2 timestamp signature
  timestamp=$(curl --silent --show-error --fail --max-time 30 "$OVH_API_URL/auth/time") || return
  signature=$(printf '%s+%s+%s+%s++%s' \
    "$OVH_APPLICATION_SECRET" "$OVH_CONSUMER_KEY" "$method" "$url" "$timestamp" \
    | openssl dgst -sha1 | awk '{ print $NF }')
  if [[ $method == POST ]]; then
    # POST sans corps : une longueur nulle est annoncée, sans type de contenu.
    curl --silent --show-error --fail --max-time 30 --request POST --data '' \
      --header 'Content-Type:' --header @- "$url"
  else
    curl --silent --show-error --fail --max-time 30 --header @- "$url"
  fi << EOF
X-Ovh-Application: $OVH_APPLICATION_KEY
X-Ovh-Consumer: $OVH_CONSUMER_KEY
X-Ovh-Timestamp: $timestamp
X-Ovh-Signature: \$1\$$signature
EOF
}

# repository_variable <nom> : valeur d'une variable déjà inscrite dans le dépôt,
# ou rien.
repository_variable() {
  jq --raw-output --arg name "$1" '.[]? | select(.name == $name) | .value' <<< "$repository_variables"
}

# setting <valeur de l'option> <variable du dépôt> <libellé>
setting() {
  local value=$1
  [[ -n $value ]] || value=$(repository_variable "$2")
  [[ -n $value ]] || read -r -p "$3 : " value || true
  [[ -n $value ]] || die "$3 : aucune valeur"
  printf '%s' "$value"
}

set_secret() { printf '%s' "$2" | gh secret set "$1" --repo "$repository"; }
set_variable() { printf '%s' "$2" | gh variable set "$1" --repo "$repository"; }

# Le bucket n'existe pas avant la première application, et sa clé S3 change
# lors d'un renouvellement : la pile s'applique donc toujours sur un état local.
use_local_state() {
  printf 'terraform {\n  backend "local" {}\n}\n' > "$ROOT/backend_override.tf"
  tofu -chdir="$ROOT" init -input=false -lockfile=readonly "$@"
}

# Relit par l'API la clé S3 du bucket des états : GitHub ne rend pas les secrets
# qu'on lui confie, et cette clé n'est conservée nulle part ailleurs.
recover_state_key() {
  local users=/cloud/project/$project_id/user user
  user=$(ovh_api GET "$users" \
    | jq --raw-output '[.[] | select(.description == "memoire-state")][0].id // empty')
  [[ -n $user ]] || die "l'utilisateur S3 « memoire-state » est introuvable dans le projet $project_id"
  AWS_ACCESS_KEY_ID=$(ovh_api GET "$users/$user/s3Credentials" | jq --raw-output '.[0].access // empty')
  [[ -n $AWS_ACCESS_KEY_ID ]] || die "l'utilisateur S3 « memoire-state » n'a plus de clé"
  AWS_SECRET_ACCESS_KEY=$(ovh_api POST "$users/$user/s3Credentials/$AWS_ACCESS_KEY_ID/secret" \
    | jq --raw-output '.secret // empty')
  [[ -n $AWS_SECRET_ACCESS_KEY ]] || die "l'API n'a pas renvoyé la clé secrète S3"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}

on_exit() {
  local status=$?
  ((status != 0)) || return 0
  if [[ -n $rotated ]]; then
    info "bootstrap.sh : arrêt après le renouvellement. Une fois la cause corrigée, relancez scripts/bootstrap.sh sans « rotate » : la commande inscrit alors les nouveaux secrets et range l'état. Avec « rotate », elle renouvellerait tout une seconde fois. Ne supprimez pas $ROOT/terraform.tfstate."
  else
    info "bootstrap.sh : arrêt avant la fin. Une fois la cause corrigée, relancez la même commande : elle reprend où elle s'était arrêtée. Ne supprimez pas $ROOT/terraform.tfstate."
  fi
}

action=bootstrap rotated='' project_id='' dns_zone='' preview_hostname='' acme_email=''
while (($# > 0)); do
  case $1 in
    rotate)
      action=rotate
      shift
      ;;
    --project-id | --dns-zone | --preview-hostname | --acme-email)
      (($# >= 2)) || usage
      case $1 in
        --project-id) project_id=$2 ;;
        --dns-zone) dns_zone=$2 ;;
        --preview-hostname) preview_hostname=$2 ;;
        --acme-email) acme_email=$2 ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

cd "$(dirname "$0")/.."

# 1. Outils et identifiants.
for tool in tofu gh jq openssl curl; do
  command -v "$tool" > /dev/null || die "la commande $tool est introuvable"
done
for name in OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY; do
  [[ -n ${!name-} ]] \
    || die "la variable $name est absente : BOOTSTRAP.md explique comment créer ces identifiants"
done
[[ ${OVH_ENDPOINT:-ovh-eu} == ovh-eu ]] \
  || die "OVH_ENDPOINT vaut « $OVH_ENDPOINT » : seul ovh-eu est pris en charge"
export OVH_ENDPOINT=ovh-eu
# Le fournisseur OVHcloud préfère un jeton ou un compte de service aux
# identifiants personnels : rien d'autre ne doit traîner dans l'environnement.
unset OVH_ACCESS_TOKEN OVH_CLIENT_ID OVH_CLIENT_SECRET

repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner) \
  || die "gh ne trouve pas le dépôt GitHub : lancez « gh auth login », depuis une copie du dépôt"
info "Dépôt GitHub : $repository"
# Les variables sont lues en une fois. Une lecture en échec ne doit pas passer
# pour une absence : l'amorçage repartirait de zéro.
repository_variables=$(gh variable list --repo "$repository" --json name,value) \
  || die "gh ne peut pas lire les variables du dépôt $repository"

# 2. Où se trouve l'état : sur ce poste après une exécution interrompue, dans
#    le bucket après une exécution réussie, nulle part la première fois.
state_bucket=$(repository_variable STATE_BUCKET)
if [[ -f $ROOT/terraform.tfstate ]]; then
  state=local
elif [[ -n $state_bucket ]]; then
  state=bucket
else
  state=none
fi
[[ $action != rotate || $state != none ]] \
  || die "rien à renouveler : l'amorçage n'a pas encore eu lieu"

# 3. Valeurs non secrètes.
project_id=$(setting "$project_id" OVH_PROJECT_ID "Identifiant du projet Public Cloud")
dns_zone=$(setting "$dns_zone" DNS_ZONE "Zone DNS hébergée chez OVHcloud")
preview_hostname=$(setting "$preview_hostname" PREVIEW_HOSTNAME "Nom complet de la préversion")
acme_email=$(setting "$acme_email" ACME_EMAIL "Adresse de contact pour les certificats")

name_pattern='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
# Même forme que celle que deploy.sh exige sur l'instance.
email_pattern='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$'
[[ $project_id =~ ^[0-9a-f]{32}$ ]] \
  || die "l'identifiant du projet compte 32 caractères hexadécimaux en minuscules"
[[ $dns_zone =~ $name_pattern ]] || die "la zone DNS « $dns_zone » est mal formée"
[[ $preview_hostname =~ $name_pattern && $preview_hostname == *".$dns_zone" ]] \
  || die "le nom « $preview_hostname » n'appartient pas à la zone $dns_zone"
[[ $acme_email =~ $email_pattern ]] || die "l'adresse « $acme_email » est mal formée"

# Le nom du projet est affiché avant toute création : un identifiant recopié
# d'un autre projet du même compte se voit ici.
project_name=$(ovh_api GET "/cloud/project/$project_id" \
  | jq --raw-output '.description // .projectName // empty') \
  || die "le projet $project_id est introuvable avec ces identifiants OVHcloud"
info "Projet Public Cloud : ${project_name:-sans nom} ($project_id)"

# 4. Phrase de passe de l'état.
if [[ -z ${STATE_PASSPHRASE-} ]]; then
  [[ $state == none ]] \
    || die "un état existe déjà : exportez STATE_PASSPHRASE avec la phrase conservée dans votre gestionnaire de mots de passe"
  STATE_PASSPHRASE=$(openssl rand -base64 32)
  info ""
  info "Phrase de passe des états OpenTofu, affichée cette seule fois :"
  info ""
  info "    $STATE_PASSPHRASE"
  info ""
  info "Enregistrez-la maintenant dans votre gestionnaire de mots de passe. Sans elle,"
  info "les états sont illisibles et OpenTofu ne peut plus rien modifier. GitHub en"
  info "recevra une copie dans le secret STATE_PASSPHRASE, qu'il ne permet pas de relire."
  info ""
  [[ ! -t 0 ]] || read -r -p "Appuyez sur Entrée une fois la phrase enregistrée. " _
fi
((${#STATE_PASSPHRASE} >= 16)) || die "la phrase de passe compte moins de 16 caractères"
export TF_VAR_state_passphrase=$STATE_PASSPHRASE
export TF_VAR_project_id=$project_id TF_VAR_dns_zone=$dns_zone

trap on_exit EXIT

# 5. Ramener l'état sur ce poste, puis appliquer.
if [[ $state == bucket ]]; then
  info "Lecture de l'état dans le bucket $state_bucket."
  recover_state_key
  STATE_BUCKET=$state_bucket
  STATE_REGION=$(repository_variable STATE_REGION)
  STATE_ENDPOINT=$(repository_variable STATE_ENDPOINT)
  export STATE_BUCKET STATE_REGION STATE_ENDPOINT
  rm -f "$ROOT/backend_override.tf"
  scripts/ci/tofu-init.sh "$ROOT" -reconfigure
  use_local_state -migrate-state -force-copy
else
  use_local_state -reconfigure
fi

if [[ $action == rotate ]]; then
  tofu -chdir="$ROOT" apply \
    -replace=ovh_me_api_oauth2_client.ci \
    -replace=ovh_cloud_project_user_s3_credential.state
  rotated=yes
else
  tofu -chdir="$ROOT" apply
fi

# 6. Inscrire les sorties dans le dépôt. Chaque valeur passe par l'entrée
#    standard de gh et n'est jamais affichée.
outputs=$(tofu -chdir="$ROOT" output -json)
output() {
  jq --exit-status --raw-output ".$1.value" <<< "$outputs" 2> /dev/null \
    || die "la sortie $1 manque à l'état"
}
ci_client_id=$(output ci_client_id)
ci_client_secret=$(output ci_client_secret)
STATE_BUCKET=$(output state_bucket)
STATE_REGION=$(output state_region)
STATE_ENDPOINT=$(output state_endpoint)
AWS_ACCESS_KEY_ID=$(output state_access_key)
AWS_SECRET_ACCESS_KEY=$(output state_secret_key)
export STATE_BUCKET STATE_REGION STATE_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
unset outputs

info "Écriture des variables et des secrets de $repository."
set_variable OVH_ENDPOINT "$OVH_ENDPOINT"
set_variable OVH_PROJECT_ID "$project_id"
set_variable STATE_BUCKET "$STATE_BUCKET"
set_variable STATE_REGION "$STATE_REGION"
set_variable STATE_ENDPOINT "$STATE_ENDPOINT"
set_variable DNS_ZONE "$dns_zone"
set_variable PREVIEW_HOSTNAME "$preview_hostname"
set_variable ACME_EMAIL "$acme_email"
set_secret OVH_CLIENT_ID "$ci_client_id"
set_secret OVH_CLIENT_SECRET "$ci_client_secret"
set_secret STATE_S3_ACCESS_KEY "$AWS_ACCESS_KEY_ID"
set_secret STATE_S3_SECRET_KEY "$AWS_SECRET_ACCESS_KEY"
set_secret STATE_PASSPHRASE "$STATE_PASSPHRASE"
# Les clés des administrateurs se choisissent avant le premier déploiement :
# une valeur déjà inscrite n'est pas écrasée.
[[ -n $(repository_variable ADMIN_SSH_PUBLIC_KEYS) ]] || set_variable ADMIN_SSH_PUBLIC_KEYS '[]'

# 7. Ranger l'état dans le bucket, avec la clé S3 en vigueur. La copie locale
#    n'est supprimée qu'après.
rm -f "$ROOT/backend_override.tf"
scripts/ci/tofu-init.sh "$ROOT" -migrate-state -force-copy
rm -f "$ROOT/terraform.tfstate" "$ROOT/terraform.tfstate.backup"

# Les workflows ne touchent à OVHcloud qu'une fois cette variable posée.
set_variable OVH_BOOTSTRAPPED true

info ""
if [[ $action == rotate ]]; then
  info "Le compte de service et la clé S3 sont renouvelés, et les secrets du dépôt mis à jour."
else
  info "Amorçage terminé. Suite des opérations, détaillée dans BOOTSTRAP.md :"
  info "  1. fusionner la pull request, ce qui lance le workflow « Déployer » ;"
  info "  2. lancer une fois le workflow « Amorcer la base », puis relancer « Déployer » ;"
  info "  3. lancer le workflow « Vérifier l'étape 1 »."
fi
info "Révoquez maintenant les identifiants personnels créés pour cette commande."
