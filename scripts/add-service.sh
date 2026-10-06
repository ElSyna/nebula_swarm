#!/usr/bin/env bash
# Ajoute un service a la stack a partir du gabarit, puis redeploie.
#   ./scripts/add-service.sh <nom> <image:tag> <port>
#   exemple : ./scripts/add-service.sh whoami traefik/whoami:v1.11 80
# L'image peut etre donnee sous son nom public : elle est copiee dans le
# registry prive si elle n'y est pas deja.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$RACINE"

NOM=${1:?usage : add-service.sh <nom> <image:tag> <port>}
IMAGE=${2:?image:tag requis}
PORT=${3:?port du conteneur requis}
[[ $NOM =~ ^[a-z][a-z0-9-]*$ ]] || erreur "nom attendu : minuscules, chiffres, tirets"
[[ $IMAGE == *:* && $IMAGE != *:latest ]] || erreur "image attendue avec un tag de version (latest interdit)"
CIBLE=swarm/services/$NOM.yml
[ ! -e "$CIBLE" ] || erreur "$CIBLE existe deja"

# Les noeuds ne tirent leurs images que du registry prive. Une image qui n'y
# est pas encore y est d'abord copiee (infra/mirror.sh).
if [[ $IMAGE != "$REGISTRY"/* ]]; then
  titre "copie de $IMAGE dans le registry"
  IMAGE=$("$RACINE/infra/mirror.sh" "$IMAGE" | tee /dev/stderr | tail -1)
fi

# Les commentaires du gabarit ne sont pas recopies.
sed -e '/^#/d' -e "s|IMAGE|$IMAGE|; s|PORT|$PORT|; s|NOM|$NOM|g" swarm/services/_gabarit.yml > "$CIBLE"
echo "== $CIBLE cree"
"$RACINE/scripts/deploy.sh"

titre "le nouveau service est route"
attendre_route "/$NOM" || erreur "/$NOM ne repond pas a travers l'edge"
