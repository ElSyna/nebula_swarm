#!/usr/bin/env bash
# Installe le registry et Portainer sur le manager (hors Swarm), puis declare
# le registry sur les workers. A lancer depuis le poste, apres 30-depot.sh.
#   ./cluster/40-infra.sh
set -euo pipefail
cd "$(dirname "$0")"; . ./nodes.env

ssh "$MANAGER" "REGISTRY_HOST=$REGISTRY_HOST REGISTRY_IP=$MANAGER_IP ~/nebula/infra/up.sh"

echo "== 6. images tierces copiees dans le registry"
ssh "$MANAGER" "REGISTRY=$REGISTRY_HOST:5000 ~/nebula/infra/mirror.sh"

echo "== 7. les workers font confiance au registry"
CA=$(ssh "$MANAGER" 'cat /srv/nebula/registry/certs/ca.crt')
for w in $WORKERS; do
  scp -q ../infra/trust.sh "$w:/tmp/nebula-trust.sh"
  printf '%s\n' "$CA" | ssh "$w" "REGISTRY_HOST=$REGISTRY_HOST bash /tmp/nebula-trust.sh $MANAGER_IP; rm -f /tmp/nebula-trust.sh"
  # 401 : la connexion TLS est acceptee, le registry demande des identifiants.
  # Les workers n'en ont pas : le manager les leur transmet au deploiement.
  ssh "$w" "echo \"   \$(hostname) : HTTP \$(curl -s -o /dev/null -w '%{http_code}' --cacert /etc/docker/certs.d/$REGISTRY_HOST:5000/ca.crt https://$REGISTRY_HOST:5000/v2/) (401 attendu)\""
done
