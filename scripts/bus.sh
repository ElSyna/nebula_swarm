#!/usr/bin/env bash
# Visibilite sur le bus, depuis le manager (le bus n'est joignable que sur le
# reseau interne : on y lance une tache ponctuelle).
#   ./scripts/bus.sh files      nombre de messages et de consommateurs par file
#   ./scripts/bus.sh poison     publie un message invalide (demonstration)
#
# publications          file de travail, consommee par worker-medias
# publications.erreurs  messages rejetes par le worker : ils y restent visibles
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sur_manager

api() {  # api <commande wget executee dans la tache>
  job nebula_bus_admin \
    --network nebula_internal \
    --secret source=nebula_bus_password,target=bus_password \
    --limit-memory 32M \
    "$REGISTRY/mirror/redis:7-alpine" sh -ec 'U="http://nebula:$(cat /run/secrets/bus_password)@bus:15672/api"; '"$1"
}

case "${1:-files}" in
  files)
    api 'wget -qO- "$U/queues?columns=name,messages,consumers" | tr "}" "\n" | sed "s/^[\[,]*{//; /^.$/d; /^$/d; s/^/   /"' ;;
  poison)
    api 'wget -qO- --header "content-type: application/json" \
           --post-data "{\"properties\":{},\"routing_key\":\"publications\",\"payload\":\"message invalide\",\"payload_encoding\":\"string\"}" \
           "$U/exchanges/%2F/amq.default/publish"; echo'
    echo "   message invalide publie : il doit apparaitre dans publications.erreurs" ;;
  *) erreur "usage : bus.sh files|poison" ;;
esac
