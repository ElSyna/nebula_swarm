#!/bin/sh
# Point d'entree commun aux services applicatifs Nebula (config Swarm).
#
# 1. Les applications lisent AMQP_URL et REDIS_URL dans leur environnement,
#    mot de passe compris. On construit ces URL ici, a partir des secrets
#    montes dans /run/secrets : aucun mot de passe dans le fichier de stack.
# 2. Arret differe : a la reception de SIGTERM, on attend DRAIN_SECONDS avant
#    de transmettre le signal. Pendant ce delai la tache repond encore, le
#    temps que l'edge la retire de sa rotation. Sans cela, les requetes
#    envoyees a une tache en cours d'arret echouent pendant une mise a jour.
set -eu

lire() { cat "/run/secrets/$1"; }

[ -f /run/secrets/bus_password ] &&
  export AMQP_URL="amqp://${BUS_USER:-nebula}:$(lire bus_password)@${BUS_HOST:-bus}:5672"
[ -f /run/secrets/cache_password ] &&
  export REDIS_URL="redis://:$(lire cache_password)@${CACHE_HOST:-cache}:6379"

"$@" &
pid=$!

trap 'sleep "${DRAIN_SECONDS:-0}"; kill -TERM "$pid" 2>/dev/null' TERM INT

# wait est interrompu par le signal : on boucle jusqu'a la fin du processus
# pour renvoyer son vrai code de sortie.
code=0
while kill -0 "$pid" 2>/dev/null; do
  wait "$pid" && code=0 || code=$?
done
exit "$code"
