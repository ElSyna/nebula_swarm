#!/usr/bin/env bash
# Analyse de vulnerabilites d'une image locale. Bloquante : code de retour
# non nul si l'image contient une vulnerabilite critique pour laquelle un
# correctif existe. Appele par build-push.sh avant toute publication.
#   ./scripts/scan.sh registry.local:5000/nebula-comptes:v1.0.0
set -euo pipefail
. "$(dirname "$0")/lib.sh"
IMAGE=${1:?usage : scan.sh <image:tag>}
SEUIL=${SEUIL:-critical}

echo "-- $IMAGE (seuil : $SEUIL, avec correctif disponible)"
# Le volume conserve la base de vulnerabilites entre deux analyses.
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v nebula_grype_db:/cache -e GRYPE_DB_CACHE_DIR=/cache \
  "$REGISTRY/mirror/grype:v0.120.0" "docker:$IMAGE" \
  --fail-on "$SEUIL" --only-fixed --quiet --output table ||
  erreur "$IMAGE : vulnerabilite $SEUIL corrigeable, publication refusee"
echo "   aucune vulnerabilite $SEUIL corrigeable"
