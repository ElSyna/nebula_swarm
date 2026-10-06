#!/usr/bin/env bash
# Forme le Swarm (1 manager, 2 workers), pose les etiquettes, puis verifie
# que le reseau applicatif passe entre les machines. A lancer depuis le poste.
#   ./cluster/20-swarm.sh
# Rejouable : un noeud deja rattache n'est pas modifie.
set -euo pipefail
cd "$(dirname "$0")"; . ./nodes.env
sur() { ssh "$1" "$2"; }
actif() { [ "$(sur "$1" "docker info --format '{{.Swarm.LocalNodeState}}'")" = active ]; }

echo "== 1. port d'administration (2377/tcp) joignable depuis les workers"
for w in $WORKERS; do
  actif "$MANAGER" || break
  sur "$w" "nc -z -w 3 $MANAGER_IP 2377 2>/dev/null" && echo "   $w -> $MANAGER_IP:2377 OK" || echo "   !! $w ne joint pas $MANAGER_IP:2377"
done

echo "== 2. formation du cluster"
# --advertise-addr : l'adresse que les autres noeuds utiliseront. Elle doit
# etre fixe et joignable ; une adresse locale (127.0.0.1) ne convient pas.
actif "$MANAGER" || sur "$MANAGER" "docker swarm init --advertise-addr $MANAGER_IP"
JETON=$(sur "$MANAGER" "docker swarm join-token -q worker")
for w in $WORKERS; do
  actif "$w" || sur "$w" "docker swarm join --token $JETON $MANAGER_IP:2377"
done

echo "== 3. etiquettes de placement"
sur "$MANAGER" "docker node update --label-add tier=data $NOEUD_DATA" >/dev/null
for n in $NOEUDS_APP; do sur "$MANAGER" "docker node update --label-add tier=app $n" >/dev/null; done

echo "== 4. reseau applicatif (4789/udp) et decouverte (7946) entre machines"
if sur "$NOEUD_DATA" "sudo nft list table inet nebula >/dev/null 2>&1"; then
  # Ce test ouvre des connexions dans tous les sens, ce que le pare-feu
  # refuse. Une fois le pare-feu pose, la verification est : 25-parefeu.sh verif
  echo "   pare-feu actif : test ignore, voir ./cluster/25-parefeu.sh verif"
else
  # Si 4789/udp est bloque, les services demarrent mais ne se voient pas. On le
  # verifie avant tout deploiement : un conteneur par noeud sur un reseau
  # overlay, et chacun doit joindre les deux autres.
  sur "$MANAGER" "docker service rm nettest >/dev/null 2>&1; docker network rm nettest >/dev/null 2>&1; sleep 2
    docker network create --driver overlay nettest >/dev/null
    docker service create --quiet --detach=false --name nettest --mode global --network nettest \
      public.ecr.aws/docker/library/busybox:1.37 sh -c 'echo ok > /tmp/index.html; httpd -f -p 80 -h /tmp' >/dev/null"
  for n in $MANAGER $WORKERS; do
    sur "$n" 'c=$(docker ps -q --filter name=nettest | head -1)
      for ip in $(docker exec $c nslookup tasks.nettest 2>/dev/null | awk "/^Address/ && !/:53/ {print \$NF}"); do
        docker exec $c wget -q -T 3 -O /dev/null http://$ip/ \
          && echo "   $(hostname) -> $ip OK" || echo "   !! $(hostname) -> $ip ECHEC (4789/udp bloque ?)"
      done'
  done
  sur "$MANAGER" "docker service rm nettest >/dev/null; sleep 3; docker network rm nettest >/dev/null"
fi

echo "== 5. cluster"
sur "$MANAGER" "docker node ls; for n in \$(docker node ls --format '{{.Hostname}}'); do docker node inspect \$n --format '   {{.Description.Hostname}}  {{.Status.Addr}}  labels={{.Spec.Labels}}'; done"
