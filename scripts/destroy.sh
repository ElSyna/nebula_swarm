#!/usr/bin/env bash
# Retire les stacks nebula et edge. A executer sur le manager.
#   ./scripts/destroy.sh
# Les volumes (donnees) et les secrets sont conserves.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sur_manager

docker stack rm --detach=false "$STACK" edge 2>&1 | grep -v '^$' || true
# Un redeploiement immediat echoue tant que les reseaux ne sont pas liberes.
for _ in $(seq 1 60); do
  [ -z "$(docker network ls -q --filter name=nebula_internal --filter name=edge_public)" ] && break
  sleep 1
done
docker service ls
