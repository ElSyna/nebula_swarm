#!/usr/bin/env bash
# Copie les images tierces de infra/images.txt dans le registry prive.
#   ./infra/mirror.sh
# A executer sur le manager, apres infra/up.sh. Rejouable : une image deja
# presente dans le registry n'est pas tiree a nouveau.
set -euo pipefail
cd "$(dirname "$0")"
REGISTRY=${REGISTRY:-registry.local:5000}

grep -vE '^\s*(#|$)' images.txt | while read -r source nom; do
  cible=$REGISTRY/mirror/$nom
  if docker manifest inspect "$cible" >/dev/null 2>&1; then
    echo "   $cible : deja present"; continue
  fi
  # Les registries publics limitent le debit : on insiste, en espacant.
  for essai in 1 2 3 4 5 6; do
    docker pull --quiet "$source" >/dev/null 2>&1 && break
    [ "$essai" = 6 ] && { echo "ERREUR : impossible de tirer $source" >&2; exit 1; }
    sleep $((essai * 10))
  done
  docker tag "$source" "$cible"
  docker push --quiet "$cible" >/dev/null
  echo "   $cible : copie depuis $source"
done
