#!/usr/bin/env bash
# Retire les stacks monitoring, nebula et edge. A executer sur le manager.
#   ./scripts/destroy.sh
# Les volumes (donnees) et les secrets sont conserves.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sur_manager

docker stack rm monitoring "$STACK" edge 2>&1 | grep -v '^$' || true

# docker stack rm rend la main avant la fin des arrets. Un redeploiement
# immediat echouerait : on attend que les taches et les reseaux aient disparu.
reste=x
for _ in $(seq 1 90); do
  reste=$(docker stack ps -q monitoring 2>/dev/null || true
          docker stack ps -q "$STACK" 2>/dev/null || true
          docker stack ps -q edge 2>/dev/null || true
          docker network ls -q --filter name=nebula_internal --filter name=edge_public)
  [ -z "$reste" ] && break
  sleep 1
done
[ -z "$reste" ] || erreur "des taches ou des reseaux sont encore presents apres 90 s (docker stack ps $STACK)"
echo "   stacks retirees, volumes et secrets conserves"
