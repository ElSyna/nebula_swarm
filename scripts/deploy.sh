#!/usr/bin/env bash
# Deploie (ou met a jour) l'edge puis Nebula. A executer sur le manager.
#   TAG=v1.0.0 ./scripts/deploy.sh
#
# Sans TAG : la version deja en service sur le cluster, sinon celle du
# fichier VERSION. Redeployer ne change donc jamais de version par accident.
# Ne construit rien : les images du tag demande doivent deja etre dans le
# registry. Rejouable sans risque : un service inchange n'est pas redemarre.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sur_manager
cd "$RACINE"

if [ -z "${TAG:-}" ]; then
  TAG=$(docker service inspect "${STACK}_comptes" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null |
        sed -n 's/.*:\(v[0-9.]*\)\(@.*\)\{0,1\}$/\1/p')
  TAG=${TAG:-$(cat VERSION)}
fi
[ "$TAG" != latest ] || erreur "le tag latest est interdit"
export REGISTRY TAG

titre "1. prerequis"
for s in nebula_db_password nebula_cache_password nebula_bus_password nebula_bus_definitions edge_admin_users; do
  docker secret inspect "$s" >/dev/null 2>&1 || erreur "secret $s absent : lancez make secrets"
done
[ -n "$(docker node ls -q --filter node.label=tier=data)" ] || erreur "aucun noeud etiquete tier=data (cluster/20-swarm.sh)"
[ -n "$(docker node ls -q --filter node.label=tier=app)" ]  || erreur "aucun noeud etiquete tier=app (cluster/20-swarm.sh)"
for s in $SERVICES_APP; do
  docker manifest inspect "$REGISTRY/nebula-$s:$TAG" >/dev/null 2>&1 ||
    erreur "image $REGISTRY/nebula-$s:$TAG introuvable dans le registry"
done
echo "   secrets, etiquettes et images $TAG presents"

# --with-registry-auth : transmet les identifiants du registry aux noeuds.
titre "2. edge"
# Lance sans attendre : l'edge demarre pendant le deploiement de nebula.
docker stack deploy --detach=true --with-registry-auth -c swarm/stack.edge.yml edge

titre "3. nebula ($TAG)"
# Chaque fichier de swarm/services/ ajoute un service a la stack.
fichiers=(-c swarm/stack.nebula.yml)
for f in swarm/services/*.yml; do
  case "$(basename "$f")" in _*|'*.yml') continue ;; esac
  fichiers+=(-c "$f")
done
# --prune : retire un service qui n'est plus decrit dans les fichiers.
docker stack deploy --detach=false --with-registry-auth --prune "${fichiers[@]}" "$STACK"

titre "4. attente de l'edge"
for _ in $(seq 1 60); do
  r=$(docker service ls --filter name=edge_traefik --format '{{.Replicas}}')
  [ -n "$r" ] && [ "${r%/*}" = "${r#*/}" ] && break
  sleep 2
done
echo "   edge_traefik $r"

"$RACINE/scripts/status.sh"
