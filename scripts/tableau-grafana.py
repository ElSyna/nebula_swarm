#!/usr/bin/env python3
# Genere config/grafana/nebula.json, le tableau de bord Nebula de Grafana.
#   python3 scripts/tableau-grafana.py config/grafana/nebula.json
# Le fichier JSON est une config Swarm : apres l'avoir regenere, changer le
# suffixe de version de nebula_grafana_tableau dans swarm/stack.monitoring.yml.
import json, sys
DS = {"type": "prometheus", "uid": "prometheus"}
SVC = 'container_label_com_docker_swarm_service_name'
panels, pid, y = [], [0], [0]

def base(titre, typ, x, w, h, cibles, unite="short", desc=None, **extra):
    pid[0] += 1
    p = {"id": pid[0], "title": titre, "type": typ, "datasource": DS,
         "gridPos": {"x": x, "y": y[0], "w": w, "h": h},
         "targets": [{"refId": chr(65 + i), "datasource": DS, "expr": e, "legendFormat": l, "instant": typ in ("stat", "bargauge", "gauge")}
                     for i, (e, l) in enumerate(cibles)],
         "fieldConfig": {"defaults": {"unit": unite, "noValue": "0"}, "overrides": []}, "options": {}}
    if desc: p["description"] = desc
    p.update(extra); panels.append(p); return p

def ligne(titre):
    pid[0] += 1
    panels.append({"id": pid[0], "type": "row", "title": titre, "collapsed": False, "gridPos": {"x": 0, "y": y[0], "w": 24, "h": 1}, "panels": []})
    y[0] += 1

def courbe(titre, x, w, cibles, unite="short", desc=None, empile=False, maxi=None, pas=False):
    p = base(titre, "timeseries", x, w, 8, cibles, unite, desc)
    c = {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 12, "showPoints": "never", "spanNulls": True}
    if empile: c.update({"stacking": {"mode": "normal", "group": "A"}, "fillOpacity": 45})
    if pas: c["lineInterpolation"] = "stepAfter"
    p["fieldConfig"]["defaults"]["custom"] = c
    p["fieldConfig"]["defaults"]["min"] = 0
    if maxi is not None: p["fieldConfig"]["defaults"]["max"] = maxi
    p["options"] = {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True}, "tooltip": {"mode": "multi", "sort": "desc"}}
    return p

def chiffre(titre, x, w, expr, unite="short", seuils=None, desc=None, decimales=None):
    p = base(titre, "stat", x, w, 4, [(expr, "")], unite, desc)
    p["options"] = {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "colorMode": "value", "graphMode": "none", "textMode": "value"}
    p["fieldConfig"]["defaults"]["thresholds"] = {"mode": "absolute", "steps": seuils or [{"color": "green", "value": None}]}
    if decimales is not None: p["fieldConfig"]["defaults"]["decimals"] = decimales
    return p

def barres(titre, x, w, cibles, unite="percent", desc=None):
    p = base(titre, "bargauge", x, w, 8, cibles, unite, desc)
    p["options"] = {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True}
    p["fieldConfig"]["defaults"].update({"min": 0, "max": 100, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 75}, {"color": "red", "value": 90}]}})
    return p

# Nom de la machine pour une adresse. Apres un redeploiement, une meme adresse
# peut avoir ete portee par deux machines dans la fenetre de lecture : on ne
# garde que le nom le plus recent, sinon Prometheus refuse la jointure.
NOM = (' * on (instance) group_left (nodename) '
       '(node_uname_info and on (instance, nodename) topk by (instance) (1, timestamp(node_uname_info)))')
ROUTE = 'label_replace(%s, "service", "$1", "service", "(.*)@swarm")'
REQ = 'traefik_service_requests_total'

# ------------------------------------------------------------------ en un coup d'oeil
ligne("En un coup d'œil")
vert_rouge = [{"color": "red", "value": None}, {"color": "green", "value": 1}]
chiffre("Machines en service", 0, 4, 'count(count by (nodename) (node_uname_info))', seuils=[{"color": "red", "value": None}, {"color": "orange", "value": 2}, {"color": "green", "value": 3}], desc="Machines dont Prometheus lit les indicateurs. Attendu : 3.")
chiffre("Sources joignables", 4, 4, 'count(up == 1) / count(up)', unite="percentunit", seuils=[{"color": "red", "value": None}, {"color": "green", "value": 1}], desc="Part des sources d'indicateurs qui répondent : edge, machines, conteneurs, bus.")
chiffre("Requêtes par seconde", 8, 4, 'sum(rate(%s[1m]))' % REQ, unite="reqps", decimales=1, desc="Toutes les requêtes reçues par l'edge, sur la dernière minute.")
chiffre("Requêtes abouties, 5 min", 12, 4, '100 * sum(rate(%s{code!~"5.."}[5m])) / sum(rate(%s[5m]))' % (REQ, REQ), unite="percent", decimales=2, seuils=[{"color": "red", "value": None}, {"color": "orange", "value": 99}, {"color": "green", "value": 99.9}], desc="Part des requêtes sans erreur serveur (5xx).")
chiffre("Messages en erreur", 16, 4, 'rabbitmq_queue_messages{queue="publications.erreurs"}', seuils=[{"color": "green", "value": None}, {"color": "orange", "value": 1}], desc="Messages rejetés par le worker et rangés dans la file publications.erreurs.")
chiffre("Workers à l'écoute", 20, 4, 'rabbitmq_queue_consumers{queue="publications"}', seuils=[{"color": "red", "value": None}, {"color": "green", "value": 1}], desc="Instances de worker-medias connectées à la file publications. Attendu : 2.")
y[0] += 4

# ------------------------------------------------------------------ point d'entree
ligne("Point d'entrée (edge)")
courbe("Requêtes par seconde, par service", 0, 8, [(ROUTE % ('sum by (service) (rate(%s[1m]))' % REQ), "{{service}}")], "reqps")
courbe("Erreurs par seconde, par service et code", 8, 8, [(ROUTE % ('sum by (service, code) (rate(%s{code=~"[45].."}[1m]))' % REQ), "{{service}} {{code}}")], "reqps", desc="Réponses 4xx et 5xx. Vide quand tout va bien.")
courbe("Durée de réponse, 95e centile", 16, 8, [(ROUTE % 'histogram_quantile(0.95, sum by (le, service) (rate(traefik_service_request_duration_seconds_bucket[1m])))', "{{service}}")], "s", desc="95 % des requêtes sont servies en moins que cette durée.")
y[0] += 8

# ------------------------------------------------------------------ services
ligne("Services")
# Un conteneur compte s'il a ete vu depuis moins d'une minute : apres un
# redemarrage de Prometheus, les series des conteneurs disparus restent
# lisibles cinq minutes et fausseraient les totaux.
VIVANT = '(time() - container_last_seen{%s}) < 60'
VERSION = ('count by (service, version) (count by (service, version, name) (label_replace(label_replace(' + VIVANT % ('%s=~"nebula_(comptes|publications|worker-medias)"' % SVC) + ', '
           '"version", "$1", "image", "^[^@]*:([^:@/]+)(@.*)?$"), "service", "$1", "%s", "nebula_(.*)")))' % SVC)
EN_VIE = ' and on (name) (' + VIVANT % ('%s!=""' % SVC) + ')'
courbe("Instances par service et version", 0, 8, [(VERSION, "{{service}} {{version}}")], "short", desc="Pendant une mise à jour, les instances de l'ancienne version cèdent la place à celles de la nouvelle, une par une.", empile=True, pas=True)
courbe("Mémoire par service", 8, 8, [('sum by (%s) (max by (%s, name) (container_memory_working_set_bytes{%s!=""}%s))' % (SVC, SVC, SVC, EN_VIE), "{{%s}}" % SVC)], "bytes")
courbe("Processeur par service", 16, 8, [('sum by (%s) (max by (%s, name) (rate(container_cpu_usage_seconds_total{%s!=""}[2m])%s))' % (SVC, SVC, SVC, EN_VIE), "{{%s}}" % SVC)], "short", desc="En cœurs de processeur utilisés.")
y[0] += 8

# ------------------------------------------------------------------ machines
ligne("Machines")
courbe("Processeur utilisé", 0, 8, [('100 * (1 - avg by (nodename) (rate(node_cpu_seconds_total{mode="idle"}[1m])%s))' % NOM, "{{nodename}}")], "percent", maxi=100)
courbe("Mémoire utilisée", 8, 8, [('max by (nodename) (100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)%s)' % NOM, "{{nodename}}")], "percent", maxi=100)
barres("Disque utilisé", 16, 8, [('max by (nodename) (100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})%s)' % NOM, "{{nodename}}")])
y[0] += 8

# ------------------------------------------------------------------ bus
ligne("Bus")
courbe("Messages en attente, par file", 0, 12, [('rabbitmq_queue_messages', "{{queue}}")], "short", desc="publications : file de travail. publications.erreurs : messages rejetés.", pas=True)
courbe("Consommateurs, par file", 12, 12, [('rabbitmq_queue_consumers', "{{queue}}")], "short", pas=True)
y[0] += 8

tableau = {"uid": "nebula", "title": "Nebula", "tags": ["nebula"], "timezone": "browser", "editable": False,
           "schemaVersion": 39, "version": 1, "refresh": "5s", "time": {"from": "now-15m", "to": "now"},
           "timepicker": {"refresh_intervals": ["5s", "10s", "30s", "1m", "5m"]},
           "graphTooltip": 1, "panels": panels, "templating": {"list": []}, "annotations": {"list": []}}
json.dump(tableau, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
print(len(panels), "panneaux,", sum(len(p.get("targets", [])) for p in panels), "requetes")
