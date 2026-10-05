#!/usr/bin/env bash
# Verifie la chaine complete : edge -> comptes -> publications -> bus -> worker
#   ./scripts/smoke.sh [url]        defaut : http://127.0.0.1 (sur un noeud)
set -euo pipefail
B=${1:-${BASE_URL:-http://127.0.0.1}}
ko=0
t() { printf '  %-46s' "$1"; shift; if "$@" >/dev/null 2>&1; then echo OK; else echo ECHEC; ko=1; fi; }
champ() { sed -n 's/.*"'"$1"'":"\{0,1\}\([^,"}]*\).*/\1/p'; }
J='content-type: application/json'

echo "== chaine applicative sur $B"
t "sante de comptes"        curl -fsS -m 5 "$B/health/comptes"
t "sante de publications"   curl -fsS -m 5 "$B/health/publications"

pseudo="smoke-$(date +%s)-$RANDOM"
id=$(curl -fsS -m 5 -X POST "$B/api/comptes" -H "$J" -d '{"pseudo":"'"$pseudo"'"}' | champ id)
t "creation d'un compte (id=$id)"           test -n "$id"
t "lecture du compte"                       curl -fsS -m 5 "$B/api/comptes/$id"
pub=$(curl -fsS -m 5 -X POST "$B/api/publications" -H "$J" -d '{"auteur_id":'"${id:-0}"',"titre":"smoke"}' | champ id)
t "publication, auteur verifie (id=$pub)"   test -n "$pub"
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$B/api/publications" -H "$J" -d '{"auteur_id":999999,"titre":"x"}')
t "auteur inconnu refuse (HTTP $code)"      test "$code" = 400
t "lecture du fil"                          curl -fsS -m 5 "$B/api/fil"

echo
echo "== cache : la 1re lecture vient de la base, la 2e du cache"
for _ in 1 2; do curl -fsS -m 5 "$B/api/fil" | champ source | sed 's/^/  source : /'; done

echo
echo "== repartition : 12 appels, par service, version et conteneur"
for s in comptes publications; do
  for _ in $(seq 1 12); do
    curl -fsS -m 5 "$B/health/$s" | sed -n 's/.*"service":"\([^"]*\)","version":"\([^"]*\)","host":"\([^"]*\)".*/\1 \2 \3/p'
  done | sort | uniq -c
done

echo
echo "== asynchrone : la trace de la publication $pub est ecrite par le worker"
echo "   docker service logs --since 1m nebula_worker-medias | grep publication-$pub"
exit $ko
