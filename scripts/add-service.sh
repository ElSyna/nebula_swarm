#!/usr/bin/env bash
# Ajoute un service a la stack a partir du gabarit, puis redeploie.
#   ./scripts/add-service.sh <nom> <image:tag> <port>
#   exemple : ./scripts/add-service.sh whoami traefik/whoami:v1.11 80
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

# Les commentaires du gabarit ne sont pas recopies.
sed -e '/^#/d' -e "s|IMAGE|$IMAGE|; s|PORT|$PORT|; s|NOM|$NOM|g" swarm/services/_gabarit.yml > "$CIBLE"
echo "== $CIBLE cree"
"$RACINE/scripts/deploy.sh"

echo
echo "== test : $BASE_URL/$NOM"
for _ in $(seq 1 15); do
  code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$BASE_URL/$NOM" || true)
  [ "$code" = 200 ] && break; sleep 2
done
echo "   HTTP $code"
