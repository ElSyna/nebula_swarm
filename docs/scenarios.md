# Les dix scénarios de vérification

Pour chaque scénario : les commandes à lancer, ce qu'elles doivent montrer,
et la sortie relevée sur le cluster les 5 et 6 octobre 2026 (dossier
[preuves/](preuves/)).

Sauf mention contraire, les commandes se lancent sur le manager, dans
`~/nebula`. « poste » désigne le poste d'administration.

| # | Scénario | Commandes | Résultat relevé |
|---|---|---|---|
| 1 | Un seul cluster | `docker node ls` | 3 nœuds `Ready` / `Active`, `manager` est `Leader` |
| 2 | Arrêt et redémarrage complet | poste : `./cluster/90-arret.sh` | service revenu seul en 116 s, 176 s, 149 s et 226 s (quatre essais), données intactes |
| 3 | Déploiement depuis zéro | `make destroy`, `make deploy TAG=v1.0.0` | 20 s + 35 s |
| 4 | Exposition | `make exposition` ; poste : `./cluster/25-parefeu.sh verif` | port 80 seul publié ; 24 ouvertures et refus conformes à la matrice de flux |
| 5 | Placement | `make status` | db et bus sur worker1, sans état sur manager et worker2 |
| 6 | Montée en charge | `make scale S=comptes N=6` | 6 instances sur 2 nœuds, toutes servent du trafic |
| 7 | Mise à jour sans interruption | `make deploy TAG=v1.1.0` | 1192 requêtes sur 1192 abouties, en 66 s |
| 8 | Version défectueuse, retour arrière | `make drill` | retour arrière terminé en 55 s, 0 requête en échec |
| 9 | Panne du plan de données | `make backup`, `make restore` | donnée conservée ; volume perdu puis restauré en 5 s |
| 10 | Ajout d'un service | `make service NOM=... IMAGE=... PORT=...` | service routé en 18 s, les sept autres non redémarrés |

## 1. Les trois machines forment un seul cluster

```bash
docker node ls
```

Trois lignes `Ready` / `Active` ; la colonne MANAGER STATUS indique `Leader`
pour `manager`. `make status` ajoute l'adresse et l'étiquette de chaque nœud.

Preuve : [scenario-01-cluster.txt](preuves/scenario-01-cluster.txt), qui
contient aussi le test du réseau entre machines.

## 2. Arrêt puis redémarrage complet

```bash
# poste
./cluster/90-arret.sh          # worker1, worker2, puis manager
# Proxmox : démarrer les trois machines, le manager en premier
# manager, après deux à quatre minutes
make status
make smoke
```

Ce qui se passe pendant l'attente : Docker démarre avec chaque machine ; le
manager relit son état Raft sur disque et retrouve la liste des services ;
les workers se reconnectent à son adresse fixe ; le registry et Portainer,
conteneurs hors Swarm, redémarrent avec Docker ; le manager relance les
tâches ; la base et le bus reviennent sur worker1 avec leurs volumes ; les
applications réessaient leurs connexions jusqu'à ce qu'ils répondent.

Si `make status` montre toutes les instances d'un service sur un seul nœud :
`make rebalance`.

Preuve : [scenario-02-redemarrage.txt](preuves/scenario-02-redemarrage.txt).
Le relevé a été fait avec `./cluster/90-arret.sh reboot` (redémarrage des
trois machines dans le même ordre, sans passer par Proxmox), pare-feu actif :
il revient avec chaque machine.

## 3. Déploiement depuis zéro

```bash
make destroy                   # retire les stacks nebula et edge
make deploy TAG=v1.0.0
make smoke
```

Les volumes et les secrets sont conservés par `make destroy` : les données
sont toujours là après le redéploiement.

Preuve : [scenario-03-deploiement.txt](preuves/scenario-03-deploiement.txt).

## 4. Contrôle de l'exposition

```bash
make exposition
# poste
./cluster/25-parefeu.sh verif
```

`make exposition` : seul `edge_traefik` a une valeur dans la colonne PORTS
(`*:80->80/tcp`). Sur manager et worker2, 80 est `OUVERT` ; 5432 (base), 5672
et 15672 (bus), 6379 (cache), 3000 (applications), 8080 et 9000 sont `ferme`
partout. worker1 ne répond sur aucun de ces ports.

`25-parefeu.sh verif` regarde depuis l'extérieur (le routeur) : seuls 22 et
80 répondent ; 2377, 5000 et 7946 sont fermés. Il contrôle ensuite le sens
des ouvertures entre machines, puis dans le réseau interne : un conteneur
de worker2 joint la base, un conteneur de worker1 ne joint ni `comptes` ni
le cache.

Preuves : [scenario-04-exposition.txt](preuves/scenario-04-exposition.txt),
[pare-feu-matrice-de-flux.txt](preuves/pare-feu-matrice-de-flux.txt).

## 5. Placement cohérent

```bash
make status
grep -n "constraints:" swarm/stack.nebula.yml swarm/stack.edge.yml
```

`nebula_db` et `nebula_bus` sont sur worker1 (`tier=data`) ; `comptes`,
`publications`, `worker-medias` et `cache` sur manager et worker2
(`tier=app`) ; l'edge sur le manager.

Preuve : [scenario-05-placement.txt](preuves/scenario-05-placement.txt).

## 6. Montée en charge d'un service sans état

```bash
make charge D=45 &             # requêtes en continu sur /health/comptes
make scale S=comptes N=6
docker service ps nebula_comptes -f desired-state=running
```

Le bilan de `make charge` compte les réponses par conteneur : les trois
nouveaux conteneurs apparaissent dans la liste. Retour à trois instances :
`make scale S=comptes N=3`.

Preuve : [scenario-06-montee-en-charge.txt](preuves/scenario-06-montee-en-charge.txt).

## 7. Mise à jour sans interruption perceptible

```bash
make charge D=110 &            # requêtes en continu pendant la mise à jour
make deploy TAG=v1.1.0
```

Le bilan compte les réponses par code HTTP et par version : uniquement des
200, d'abord en v1.0.0 puis en v1.1.0, et « 0 en echec ».

Preuve : [scenario-07-mise-a-jour.txt](preuves/scenario-07-mise-a-jour.txt).

## 8. Version défectueuse puis retour arrière

```bash
make drill                     # ou : make drill S=publications M=crash
```

Le script publie une image dont `/health` répond 500, met à jour `comptes`
avec, et chronomètre. La sonde de santé déclare la nouvelle tâche en échec ;
Swarm revient à la version précédente (`rollback_completed`). Les anciennes
tâches n'ont jamais été arrêtées : le bilan des requêtes affiche « 0 en
echec ».

Preuve : [scenario-08-retour-arriere.txt](preuves/scenario-08-retour-arriere.txt).

## 9. Panne du plan de données

Arrêt puis relance de la base :

```bash
docker service scale nebula_db=0
curl -s -o /dev/null -w '%{http_code}\n' localhost/api/comptes/1    # 500
docker service scale nebula_db=1
curl -s localhost/api/comptes/1                                     # le compte est là
```

Perte du volume, puis restauration :

```bash
make backup
docker service scale nebula_db=0
# worker1 :
docker rm $(docker ps -aq --filter volume=nebula_db_data); docker volume rm nebula_db_data
# manager :
docker service scale nebula_db=1       # base vide, schéma recréé par db/init.sql
make restore
```

Preuve : [scenario-09-restauration.txt](preuves/scenario-09-restauration.txt).

## 10. Ajout d'un service imprévu

```bash
make service NOM=whoami IMAGE=registry.local:5000/mirror/whoami:v1.11 PORT=80
curl localhost/whoami
```

Un fichier `swarm/services/whoami.yml` est créé à partir du gabarit ; aucun
autre fichier n'est modifié. Le service est routé sur `/whoami` par ses
labels. Dans l'état du cluster affiché en fin de commande, les sept autres
services gardent leur ancienneté (`Running ... minutes ago`).

L'image peut être donnée sous son nom public (`IMAGE=nginx:1.29-alpine`) :
elle est d'abord copiée dans le registry privé, les nœuds n'ayant pas accès
aux registries publics. Relevé avec nginx : 28 s, copie comprise. Pour un service qui a besoin
de la base, du bus ou du cache : ajouter `internal` à `networks` et la liste
`secrets` dans le fichier créé (voir les commentaires du gabarit).

Retrait : `rm swarm/services/whoami.yml && make deploy`.

Le fichier créé est sur le manager. Pour le garder : `git add -A && git
commit` sur le manager, puis sur le poste `git pull cluster main && git push
origin main`.

Preuve : [scenario-10-ajout-service.txt](preuves/scenario-10-ajout-service.txt).

## Autres relevés

- [essais-complementaires.txt](preuves/essais-complementaires.txt) : seize
  lignes ou protections retirées pour de vrai, redémarrage du bus seul, nœud
  de données puis manager absents plusieurs minutes, exercice de retour
  arrière en mode arrêt immédiat.
- [livraison-github-actions.txt](preuves/livraison-github-actions.txt) :
  exécutions GitHub Actions de la CI (tag `v1.2.0`) et du CD.
- [livraison-construction.txt](preuves/livraison-construction.txt) :
  construction, analyse, tag et publication de v1.1.0 ; refus d'un tag déjà
  publié ; refus de publication quand l'analyse dépasse le seuil.
- [supervision.txt](preuves/supervision.txt) : services de supervision,
  sources lues par Prometheus, accès à Grafana, valeur de chaque graphique.
- [sauvegarde-planifiee.txt](preuves/sauvegarde-planifiee.txt) : sauvegarde
  déclenchée par le minuteur, restaurée, et rétention.
- [registry.txt](preuves/registry.txt) : contenu du registry, refus sans
  identifiants, images présentes sur les trois machines.
- [bus-messages-en-erreur.txt](preuves/bus-messages-en-erreur.txt) : un
  message rejeté par le worker reste visible dans `publications.erreurs`.
