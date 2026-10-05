#!/usr/bin/env bash
# Exercice : deployer une version defectueuse, constater l'echec, mesurer le
# retour arriere. A executer sur le manager.
#   ./scripts/drill-rollback.sh [service] [sonde|crash]     defaut : comptes sonde
#
#   sonde : l'image demarre mais /health repond 500 -> jamais saine
#   crash : l'image s'arrete des le demarrage
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sur_manager

SVC=${1:-comptes}
MODE=${2:-sonde}
ACTUELLE=$(docker service inspect "${STACK}_$SVC" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')
ACTUELLE=${ACTUELLE%@*}
DEFAUT="$ACTUELLE-defaut-$MODE"

titre "1. version en place : $ACTUELLE"
case "$MODE" in
  sonde) casse="RUN printf 'require(\"node:http\").createServer((q,r)=>{r.statusCode=500;r.end()}).listen(3000)' > src/index.js" ;;
  crash) casse="RUN rm src/index.js" ;;
  *) erreur "mode attendu : sonde ou crash" ;;
esac
printf 'FROM %s\nUSER root\n%s\nUSER node\n' "$ACTUELLE" "$casse" | docker build --quiet -t "$DEFAUT" - >/dev/null
docker push --quiet "$DEFAUT" >/dev/null
echo "   version defectueuse publiee : $DEFAUT"

titre "2. mise a jour vers la version defectueuse (requetes en continu en parallele)"
"$RACINE/scripts/charge.sh" "${DUREE:-120}" "/health/$SVC" > /tmp/drill-charge.txt 2>&1 &
charge=$!
debut=$(date +%s)
docker service update --quiet --detach --with-registry-auth --image "$DEFAUT" "${STACK}_$SVC" >/dev/null

etat=""; vu=""
while :; do
  etat=$(docker service inspect "${STACK}_$SVC" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}')
  if [ "$etat" != "$vu" ]; then printf '   +%3ss  %s\n' "$(( $(date +%s) - debut ))" "$etat"; vu=$etat; fi
  case "$etat" in rollback_completed|completed|paused|rollback_paused) break ;; esac
  sleep 1
done
duree=$(( $(date +%s) - debut ))

titre "3. constat"
docker service ps "${STACK}_$SVC" --no-trunc --format '{{.Name}}\t{{.Image}}\t{{.Node}}\t{{.CurrentState}}\t{{.Error}}' |
  grep -E 'Running|defaut' | sed -e 's/@sha256:[0-9a-f]*//' -e 's/^/   /' 
docker service inspect "${STACK}_$SVC" --format '   message : {{.UpdateStatus.Message}}'
docker service inspect "${STACK}_$SVC" --format '   image du service : {{.Spec.TaskTemplate.ContainerSpec.Image}}'
echo "   etat final : $etat, $duree s entre la mise a jour et la fin du retour arriere"

titre "4. requetes emises pendant l'incident"
kill "$charge" 2>/dev/null || true; wait "$charge" 2>/dev/null || true
sed -n '/par code/,$p' /tmp/drill-charge.txt
