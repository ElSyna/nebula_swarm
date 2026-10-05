#!/usr/bin/env bash
# Emet des requetes en continu et fait le bilan. Sert a prouver qu'une mise a
# jour ou une montee en charge n'interrompt pas le service.
#   ./scripts/charge.sh [duree_s] [chemin]     defaut : 60 s sur /health/comptes
set -euo pipefail
. "$(dirname "$0")/lib.sh"
DUREE=${1:-60}
CHEMIN=${2:-/health/comptes}
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

echo "== $DUREE s de requetes sur $BASE_URL$CHEMIN"
fin=$((SECONDS + DUREE))
trap 'fin=0' TERM INT          # arret anticipe : on fait quand meme le bilan
while [ $SECONDS -lt $fin ]; do
  # Une ligne par requete : code HTTP, version, conteneur.
  rep=$(curl -s -m 5 -w '\n%{http_code}' "$BASE_URL$CHEMIN" || true)
  code=${rep##*$'\n'}
  version=$(printf '%s' "$rep" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  hote=$(printf '%s' "$rep" | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')
  echo "$code ${version:--} ${hote:--}" >> "$tmp"
  sleep 0.05
done

total=$(wc -l < "$tmp")
ok=$(grep -c '^2' "$tmp" || true)
echo
echo "-- par code HTTP et version"
awk '{print $1, $2}' "$tmp" | sort | uniq -c
echo "-- par conteneur"
awk '{print $3}' "$tmp" | sort | uniq -c
echo
echo "bilan : $ok requetes abouties sur $total, $((total - ok)) en echec"
[ "$ok" = "$total" ]
