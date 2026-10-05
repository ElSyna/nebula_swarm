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
for st in edge "$STACK"; do
  docker stack ps "$st" --filter desired-state=running \
    --format '{{.Name}}\t{{.Image}}\t{{.Node}}\t{{.CurrentState}}' 2>/dev/null || true
done | sort | column -t -s "$(printf '\t')"
