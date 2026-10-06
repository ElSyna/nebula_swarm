#!/usr/bin/env bash
# Etat du cluster : noeuds, services, et pour chaque instance la version et
# la machine. A executer sur le manager.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sur_manager

titre "noeuds"
docker node ls --format 'table {{.Hostname}}\t{{.Status}}\t{{.Availability}}\t{{.ManagerStatus}}\t{{.EngineVersion}}'
for n in $(docker node ls --format '{{.Hostname}}'); do
  docker node inspect "$n" --format '   {{.Description.Hostname}}  {{.Status.Addr}}  labels={{.Spec.Labels}}'
done

titre "services"
docker service ls --format 'table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}\t{{.Ports}}'

titre "instances (service, version, machine)"
for st in edge "$STACK" monitoring; do
  docker stack ps "$st" --filter desired-state=running \
    --format '{{.Name}}\t{{.Image}}\t{{.Node}}\t{{.CurrentState}}' 2>/dev/null || true
done | sort | column -t -s "$(printf '\t')"

titre "sauvegardes de la base"
derniere=$(ls -1t /srv/nebula/backups/nebula-*.dump 2>/dev/null | head -1 || true)
if [ -n "$derniere" ]; then
  echo "   derniere : $(basename "$derniere"), il y a $(( ($(date +%s) - $(stat -c %Y "$derniere")) / 3600 )) h"
  echo "   prochaine : $(systemctl show nebula-sauvegarde.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)"
else
  echo "   aucune sauvegarde dans /srv/nebula/backups"
fi
