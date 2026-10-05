#!/usr/bin/env bash
# Controle de l'exposition : quels ports repondent sur chaque noeud.
#   ./scripts/exposition.sh
# Attendu : 80 sur les trois noeuds (edge, seul port publie par le cluster).
# 5000 repond sur le manager : c'est le registry, installe hors cluster.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sur_manager

PORTS="80:edge 5432:postgres 5672:amqp 15672:rabbitmq-admin 6379:redis 3000:applications 8080:traefik 9000:portainer 5000:registry"

titre "ports publies par le cluster"
docker service ls --format 'table {{.Name}}\t{{.Ports}}'

titre "ports qui repondent, noeud par noeud"
for n in $(docker node ls --format '{{.Hostname}}'); do
  ip=$(docker node inspect "$n" --format '{{.Status.Addr}}')
  printf '%-9s %-15s' "$n" "$ip"
  for p in $PORTS; do
    if nc -z -w 2 "$ip" "${p%%:*}" 2>/dev/null; then printf ' %s=OUVERT' "${p%%:*}"; else printf ' %s=ferme' "${p%%:*}"; fi
  done
  echo
done
echo
echo "legende : $PORTS"
