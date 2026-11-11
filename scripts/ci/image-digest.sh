#!/usr/bin/env bash
#
# image-digest.sh : affiche l'empreinte que le registre associe à une image.
#
# Usage : scripts/ci/image-digest.sh <dépôt>:<étiquette>
#   scripts/ci/image-digest.sh ghcr.io/arnaudlut/memories:<identifiant du commit>
#
# L'instance ne lance une image que désignée par son empreinte. Celle-ci est
# demandée au registre lui-même : c'est ce qui y est publié sous l'étiquette qui
# fait foi, quelle que soit la machine qui a construit l'image. Docker doit
# déjà être connecté au registre.

set -euo pipefail

(($# == 1)) || {
  echo "usage : image-digest.sh <dépôt>:<étiquette>" >&2
  exit 2
}

digest=$(docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq --raw-output '.digest') || {
  echo "image-digest.sh : l'image $1 est introuvable. Le workflow « Déployer » l'a-t-il publiée pour ce commit ?" >&2
  exit 1
}
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "image-digest.sh : le registre n'a pas renvoyé d'empreinte pour $1" >&2
  exit 1
}
echo "$digest"
