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
# Version en service avant ce deploiement, pour dire comment y revenir.
AVANT=$(docker service inspect "${STACK}_comptes" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null | sed -e 's/@.*//' -e 's/.*://' || true)

titre "1. prerequis"
for s in nebula_db_password nebula_cache_password nebula_bus_password nebula_bus_definitions nebula_grafana_password edge_admin_users; do
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
# --detach=true : on rend la main tout de suite et on suit la convergence
# nous-memes (etape 4), pour les deux stacks en parallele.
titre "2. edge"
docker stack deploy --detach=true --with-registry-auth -c swarm/stack.edge.yml edge

titre "3. nebula ($TAG)"
# Chaque fichier de swarm/services/ ajoute un service a la stack.
fichiers=(-c swarm/stack.nebula.yml)
for f in swarm/services/*.yml; do
  case "$(basename "$f")" in _*|'*.yml') continue ;; esac
  fichiers+=(-c "$f")
done
# --prune : retire un service qui n'est plus decrit dans les fichiers.
docker stack deploy --detach=true --with-registry-auth --prune "${fichiers[@]}" "$STACK"

titre "4. convergence"
# Termine quand chaque service de l'edge et de nebula a toutes ses instances
# et qu'aucune mise a jour (ou retour arriere) n'est en cours.
debut=$SECONDS; vu=""
sleep 2
for _ in $(seq 1 240); do
  instances=$(docker service ls --format '{{.Name}}={{.Replicas}}' | grep -v '^monitoring_' | sort | tr '\n' ' ')
  majs=$(docker service inspect $(docker service ls --format '{{.Name}}' | grep -v '^monitoring_') \
    --format '{{if .UpdateStatus}}{{.Spec.Name}}:{{.UpdateStatus.State}} {{end}}' | tr -d '\n')
  attente=$(tr ' ' '\n' <<< "$instances" | awk -F'[=/]' 'NF==3 && $2 < $3 {print $1}' | tr '\n' ' ')
  encours=$(tr ' ' '\n' <<< "$majs" | grep -E ':(updating|rollback_started)$' | tr '\n' ' ' || true)
  etat="${attente:+en attente : $attente}${encours:+en cours : $encours}"
  if [ "$etat" != "$vu" ]; then printf '   +%3ss  %s\n' "$((SECONDS - debut))" "${etat:-tous les services sont a leur nombre d instances}"; vu=$etat; fi
  [ -z "$etat" ] && break
  sleep 2
done
[ -z "$etat" ] || erreur "convergence non atteinte : $etat"

# Si une tache de la nouvelle version a echoue, Swarm est revenu seul a la
# version precedente : l'image du service n'est alors pas celle demandee.
for s in $SERVICES_APP; do
  image=$(docker service inspect "${STACK}_$s" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')
  case "${image%@*}" in *":$TAG") ;; *)
    echo "ERREUR : ${STACK}_$s est en ${image%@*} et non en $TAG : mise a jour refusee, retour arriere effectue sur ce service." >&2
    echo "         Les services dont la mise a jour a reussi sont en $TAG. Pour tout remettre dans la meme version : make deploy TAG=${AVANT:-<version precedente>}" >&2
    exit 1 ;;
  esac
done

titre "5. l'edge route les services"
# L'edge relit l'etat du cluster toutes les 5 s et sonde chaque tache avant
# de lui envoyer du trafic : on attend que les routes repondent.
for s in comptes publications; do
  attendre_route "/health/$s" || erreur "/health/$s ne repond pas a travers l'edge"
done

titre "6. supervision"
# Prometheus et Grafana empruntent les reseaux de l'edge et de nebula. Ils
# sont lances une fois l'application en service, et on ne les attend pas :
# la supervision ne retarde jamais un deploiement.
docker stack deploy --detach=true --with-registry-auth -c swarm/stack.monitoring.yml monitoring 2>&1 | grep -v '^$' || true
echo "   Grafana : $BASE_URL/grafana (pret en une minute environ)"

"$RACINE/scripts/status.sh"
