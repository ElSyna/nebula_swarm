#!/usr/bin/env bash
# Verifie la supervision. A executer sur le manager.
#   ./scripts/verif-supervision.sh [minutes]      defaut : 30
#
# 1. chaque source de Prometheus repond ;
# 2. chaque requete du tableau de bord est rejouee sur une plage de temps,
#    comme le fait Grafana. Une requete peut reussir a l'instant present et
#    echouer sur une plage : c'est la plage qu'il faut tester.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sur_manager
MINUTES=${1:-30}
P=$(docker ps -q --filter name=monitoring_prometheus | head -1)
[ -n "$P" ] || erreur "Prometheus ne tourne pas sur ce noeud (make deploy)"

titre "sources lues par Prometheus"
docker exec "$P" wget -qO- 'http://127.0.0.1:9090/api/v1/targets?state=active' | python3 -c '
import json, sys
cibles = json.load(sys.stdin)["data"]["activeTargets"]
for c in sorted(cibles, key=lambda c: c["labels"]["job"]):
    print("   %-11s %-44s %s" % (c["labels"]["job"], c["scrapeUrl"], c["health"]))
sys.exit(0 if all(c["health"] == "up" for c in cibles) else 1)' || erreur "une source ne repond pas"

titre "requetes du tableau de bord, sur $MINUTES minutes"
python3 - "$P" "$MINUTES" "$RACINE/config/grafana/nebula.json" <<'PY'
import json, subprocess, sys, time, urllib.parse
conteneur, minutes, fichier = sys.argv[1], int(sys.argv[2]), sys.argv[3]
fin = int(time.time()); debut = fin - 60 * minutes; erreurs = 0
for panneau in json.load(open(fichier))["panels"]:
    for cible in panneau.get("targets", []):
        url = "http://127.0.0.1:9090/api/v1/query_range?start=%d&end=%d&step=15&query=%s" % (debut, fin, urllib.parse.quote(cible["expr"]))
        sortie = subprocess.run(["docker", "exec", conteneur, "wget", "-qO-", url], capture_output=True, text=True).stdout
        try:
            series = json.loads(sortie)["data"]["result"]
            print("   OK      %-42s %2d serie(s)" % (panneau["title"], len(series)))
        except Exception:
            erreurs += 1
            print("   ERREUR  %s" % panneau["title"])
print()
print("aucune requete en erreur" if not erreurs else "%d requete(s) en erreur" % erreurs)
sys.exit(1 if erreurs else 0)
PY
