#!/usr/bin/env bash
# Copie des images tierces dans le registry prive, sous mirror/.
# A executer sur le manager, apres infra/up.sh.
#   ./infra/mirror.sh                      toutes les images de infra/images.txt
#   ./infra/mirror.sh nginx:1.29-alpine    une image de plus, ajoutee a la liste
#
# Rejouable : une image deja presente dans le registry n'est pas tiree.
# La derniere ligne affichee est toujours le nom de l'image dans le registry.
set -euo pipefail
cd "$(dirname "$0")"
REGISTRY=${REGISTRY:-registry.local:5000}

tirer() {   # tirer <source> : insiste, les registries publics limitent le debit
  local essai
  for essai in 1 2 3; do
    docker pull --quiet "$1" >/dev/null 2>&1 && return 0
    sleep $((essai * 8))
  done
  return 1
}

copier() {  # copier <source> <nom dans mirror/>
  local cible=$REGISTRY/mirror/$2
  if docker manifest inspect "$cible" >/dev/null 2>&1; then
    echo "   $cible : deja present"; return 0
  fi
  tirer "$1" || return 1
  docker tag "$1" "$cible"
  docker push --quiet "$cible" >/dev/null
  echo "   $cible : copie depuis $1"
}

if [ $# -eq 0 ]; then
  grep -vE '^\s*(#|$)' images.txt | while read -r source nom; do
    copier "$source" "$nom" || { echo "ERREUR : impossible de tirer $source" >&2; exit 1; }
  done
  exit 0
fi

# Une image donnee en argument : on cherche ou la prendre.
image=$1
[[ $image == *:* && $image != *:latest ]] || { echo "ERREUR : image attendue avec un tag de version (latest interdit)" >&2; exit 1; }
nom=${image##*/}                      # traefik/whoami:v1.11 -> whoami:v1.11
premier=${image%%/*}
if [[ $image == */* && ( $premier == *.* || $premier == *:* ) ]]; then
  sources=("$image")                                          # registry explicite
elif [[ $image != */* ]]; then
  # Image officielle : le miroir public d'Amazon d'abord, Docker Hub limitant
  # les tirages par adresse IP.
  sources=("public.ecr.aws/docker/library/$image" "docker.io/library/$image")
else
  sources=("docker.io/$image" "ghcr.io/$image" "quay.io/$image")
fi
for source in "${sources[@]}"; do
  if copier "$source" "$nom"; then
    grep -qE "[[:space:]]$nom\$" images.txt || printf '%-60s %s\n' "$source" "$nom" >> images.txt
    echo "$REGISTRY/mirror/$nom"
    exit 0
  fi
  echo "   $source : indisponible" >&2
done
echo "ERREUR : $image introuvable (sources essayees : ${sources[*]})" >&2
exit 1
