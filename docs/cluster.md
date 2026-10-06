# Construction du cluster depuis zéro

Tout se lance depuis le poste d'administration, à la racine du dépôt, sauf la
création des machines (sur l'hôte Proxmox).

| Étape | Commande |
|---|---|
| 1. Créer les trois machines | `cluster/00-vm-proxmox.sh` (hôte Proxmox) |
| 2. Installer Docker | `./cluster/10-docker.sh` |
| 3. Former le Swarm, étiqueter, tester le réseau | `./cluster/20-swarm.sh` |
| 4. Poser le pare-feu | `./cluster/25-parefeu.sh` |
| 5. Déposer le dépôt sur le manager | `./cluster/30-depot.sh` |
| 6. Registry, images tierces, Portainer | `./cluster/40-infra.sh` |
| 7. Planifier les sauvegardes | `./cluster/45-sauvegardes.sh` |
| 8. Runner de livraison | `./cluster/50-runner.sh` |

Les scripts 10 à 40 sont rejouables : ce qui est déjà en place n'est pas modifié.
Le cluster est ensuite prêt pour le déploiement initial ([procedures.md](procedures.md)).

## 1. Les trois machines

Machines virtuelles KVM sur Proxmox VE, réseau `vn1021` (10.96.253.0/24,
passerelle 10.96.253.254), image cloud Debian 13.

| Nom | Rôle Swarm | Adresse | vCPU | Mémoire | Disque | Étiquette |
|---|---|---|---|---|---|---|
| `manager` | manager | 10.96.253.211 | 2 | 4 Go | 32 Go | `tier=app` |
| `worker1` | worker | 10.96.253.212 | 2 | 4 Go | 32 Go | `tier=data` |
| `worker2` | worker | 10.96.253.213 | 2 | 2 Go | 20 Go | `tier=app` |

- **Adresses fixes.** Elles sont posées par cloud-init (`--ipconfig0` dans
  `00-vm-proxmox.sh`), pas par DHCP. Le Swarm enregistre l'adresse de chaque
  nœud : si elle changeait au redémarrage, le cluster ne se reformerait pas.
- **Accès.** Utilisateur `ubuntu`, clé SSH, `sudo` sans mot de passe. Les
  machines ne sont joignables qu'à travers le routeur du réseau. Extrait du
  `~/.ssh/config` du poste, dont les scripts utilisent les alias :

  ```
  Host router
      HostName 10.210.0.34
      User root
  Host manager
      HostName 10.96.253.211
  Host worker1
      HostName 10.96.253.212
  Host worker2
      HostName 10.96.253.213
  Host manager worker1 worker2
      User ubuntu
      ProxyJump router
  ```

- **`/etc/hosts` est réécrit à chaque démarrage** par cloud-init
  (`manage_etc_hosts`). Toute ligne ajoutée à la main disparaît au
  redémarrage : `infra/trust.sh` écrit donc le nom du registry dans
  `/etc/hosts` **et** dans le modèle `/etc/cloud/templates/hosts.debian.tmpl`.

## 2. Docker

`cluster/10-docker.sh` installe Docker Engine depuis le dépôt officiel
(`download.docker.com`), ainsi que `make`, `git`, `nc` et `htpasswd`. Il pose
`/etc/docker/daemon.json` :

```json
{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }
```

Les journaux de chaque conteneur sont bornés à 30 Mo. Le service `docker` est
activé au démarrage (`systemctl enable`) : c'est lui qui reforme le cluster
quand les machines se rallument.

## 3. Swarm

`cluster/20-swarm.sh` lit `cluster/nodes.env` et :

1. vérifie que les workers joignent le port 2377/tcp du manager ;
2. initialise le Swarm avec `--advertise-addr 10.96.253.211` et rattache les
   deux workers ;
3. pose les étiquettes `tier=data` (worker1) et `tier=app` (manager, worker2) ;
4. lance un conteneur par nœud sur un réseau overlay de test, et vérifie que
   chacun joint les deux autres. C'est le test du port 4789/udp : s'il est
   bloqué, les services démarrent mais ne se voient pas.

Ports utilisés entre les nœuds : 2377/tcp (administration), 7946/tcp et udp
(découverte), 4789/udp (réseau applicatif). Ce sont les seuls ouverts entre
les machines, avec le registry : voir la matrice de flux, section 4.

Preuve : [preuves/scenario-01-cluster.txt](preuves/scenario-01-cluster.txt).

### Topologie : un manager, deux workers

Le Swarm garde son état dans un journal Raft tenu par les managers. Une
décision demande la majorité des managers : avec 1 manager la tolérance est
de 0 panne, avec 3 managers de 1 panne (quorum de 2).

Choix retenu : **1 manager, 2 workers**.

- Trois managers protègent le plan de contrôle contre la perte d'une
  machine. Ils ne protègent pas l'application : la base n'existe qu'en un
  exemplaire, sur un seul nœud (une seule instance est demandée, annexe C).
  Perdre worker1 arrête Nebula quelle que soit la topologie.
- Au redémarrage complet, un cluster à trois managers n'accepte aucun ordre
  tant que deux managers ne sont pas revenus et ne se sont pas retrouvés.
  Avec un seul manager, le cluster est opérationnel dès que le manager a
  démarré, et les workers le rejoignent à leur rythme.
- Un manager porte le journal Raft et l'API. Sur des machines de 2 à 4 Go,
  les workers restent disponibles pour les services.

Limite assumée : le manager est un point de défaillance unique. S'il tombe,
plus aucun ordre n'est possible (déploiement, changement d'échelle,
replacement d'une tâche) et l'edge, qui tourne sur le manager, ne répond
plus. Les conteneurs des workers continuent de tourner. Le manager revient
avec son état Raft, conservé sur son disque (`/var/lib/docker/swarm`).

### Placement

| Étiquette | Nœuds | Services |
|---|---|---|
| `tier=data` | worker1 | `db`, `bus` |
| `tier=app` | manager, worker2 | `comptes`, `publications`, `worker-medias`, `cache` |
| `node.role == manager` | manager | `edge` (il lit l'API du cluster) |

La base est sur worker1 parce que son volume est local à la machine : la
contrainte garantit qu'elle y revient toujours. worker1 ne porte rien
d'autre que les données. Les services sans état sont sur les deux autres
machines : la perte de l'une des deux les laisse disponibles sur l'autre.

## 4. Pare-feu et matrice de flux

`cluster/25-parefeu.sh` pose sur chaque machine une table nftables
`inet nebula`. Tout ce qui entre est refusé par défaut ; seules les
ouvertures ci-dessous existent, et chacune a un sens : la source peut ouvrir
une connexion vers la destination, pas l'inverse.

| Source | Destination | Port | Usage | Sens inverse |
|---|---|---|---|---|
| routeur 10.96.253.254 | les trois machines | 22/tcp | SSH d'administration | refusé, y compris d'une machine à l'autre |
| tout client | manager, worker2 | 80/tcp | edge | fermé sur worker1 |
| worker1, worker2 | manager | 2377/tcp | administration du Swarm | refusé |
| worker1, worker2 | manager | 5000/tcp | registry | refusé |
| chaque nœud | chaque nœud | 7946/tcp et udp | découverte entre nœuds | symétrique |
| chaque nœud | chaque nœud | 4789/udp | transport du réseau overlay | symétrique, filtré à l'intérieur : lignes suivantes |
| conteneurs de manager et worker2 | conteneurs de worker1 | TCP 5432, 5672, 15672, dans l'overlay | base et bus | refusé : worker1 n'ouvre aucune connexion TCP vers les nœuds applicatifs |
| Prometheus (manager) | conteneurs de worker1 | TCP 15692, 9100, 8080, dans l'overlay | indicateurs du bus, de la machine, des conteneurs | refusé |
| conteneurs de manager | conteneurs de worker2 | TCP, dans l'overlay | services sans état entre eux, edge vers les services | autorisé (même niveau) |

- **Le sens dans le réseau overlay.** Le transport VXLAN (4789/udp) circule
  forcément dans les deux sens. La règle regarde donc dans le paquet
  encapsulé (`vxlan tcp flags`) et refuse le premier paquet d'une connexion,
  un SYN sans ACK, quand il vient du mauvais côté. Les réponses passent. Les
  nœuds applicatifs lisent la base et le bus ; le nœud de données ne peut
  ouvrir aucune connexion vers eux.
- **Ports publiés par Docker** (80, 5000). Docker les redirige vers ses
  conteneurs avant la chaîne `input`. Ils sont filtrés dans une chaîne
  `prerouting`, placée avant cette redirection.
- **Table à part.** Les tables que Docker gère lui-même ne sont pas
  modifiées. Le service `nebula-parefeu` charge `/etc/nebula/parefeu.nft` au
  démarrage, avant Docker.
- **Pose sans se couper l'accès.** Avant de charger les règles, le script
  programme leur retrait dans trois minutes. Il n'annule ce retrait, et ne
  rend les règles durables, qu'après avoir réussi une nouvelle connexion SSH.
- **Vérification.** `./cluster/25-parefeu.sh verif` contrôle 24 ouvertures
  et refus : depuis le routeur, d'une machine à l'autre, et depuis des
  conteneurs du réseau interne. `./cluster/25-parefeu.sh regles` affiche les
  règles de chaque nœud, `off` retire le pare-feu.

Limites : la sortie des machines n'est pas filtrée ; dans l'overlay, le sens
n'est contrôlé que pour TCP. Un service ajouté sur le nœud de données et
écoutant sur un autre port demande d'ajouter ce port à `PORTS_DATA` dans
`cluster/nodes.env`, puis de relancer le script.

Le test du réseau de `20-swarm.sh` (étape 3) ouvre des connexions dans tous
les sens : il se joue avant la pose du pare-feu, et il est ignoré ensuite.

Preuve : [preuves/pare-feu-matrice-de-flux.txt](preuves/pare-feu-matrice-de-flux.txt).

## 5. Registry, images tierces, Portainer

`cluster/40-infra.sh` exécute sur le manager `infra/up.sh` puis
`infra/mirror.sh`, et déclare le registry sur les workers.

- **Registry** (`infra/compose.yaml`) : conteneur Docker Compose sur le
  manager, hors Swarm, `restart: unless-stopped`. Il redémarre avec le daemon
  Docker de la machine, sans dépendre du cluster. TLS (autorité locale créée
  par `up.sh`) et authentification htpasswd. Nom `registry.local:5000`.
- **Chaque nœud** reçoit l'autorité de certification dans
  `/etc/docker/certs.d/registry.local:5000/ca.crt` et le nom `registry.local`
  (`infra/trust.sh`). Aucun `insecure-registries`, aucun redémarrage du
  daemon.
- **Identifiants.** Seul le manager fait `docker login`. Les workers
  reçoivent les identifiants au déploiement (`--with-registry-auth`).
- **Images tierces** (`infra/images.txt`) : traefik, postgres, redis,
  rabbitmq, node, whoami sont copiées dans le registry sous `mirror/`. Docker
  Hub limite les tirages à 100 par heure et par adresse IP, et l'adresse
  publique du réseau est partagée : le quota était à zéro pendant la
  construction. Les images officielles sont prises sur le miroir public
  `public.ecr.aws/docker/library`. Une fois copiées, le cluster ne dépend
  plus d'aucun registry public. Une image de plus : `make image
  I=nginx:1.29-alpine` sur le manager, qui l'ajoute aussi à la liste.
- **Portainer** : même fichier Compose, écoute sur `127.0.0.1:9000` du
  manager uniquement. Accès : `ssh -L 9000:127.0.0.1:9000 manager`, puis
  `http://localhost:9000`, compte `admin`.

Ce qui n'est pas dans le dépôt, et où cela se trouve sur le manager :

| Élément | Emplacement |
|---|---|
| Autorité et certificat du registry, fichier htpasswd | `/srv/nebula/registry/` |
| Mot de passe administrateur de Portainer | `/srv/nebula/portainer/` |
| Identifiants à connaître d'un humain (registry, Portainer, edge, Grafana) | `~/.nebula/identifiants` (mode 600) |
| Sauvegardes de la base | `/srv/nebula/backups/` |
| Secrets applicatifs | dans le Swarm (`docker secret ls`) |

Preuve : [preuves/registry.txt](preuves/registry.txt).

## 6. Sauvegardes planifiées

`cluster/45-sauvegardes.sh` installe sur le manager un minuteur systemd,
`nebula-sauvegarde.timer`, hors Swarm. Chaque jour à 02:30 UTC il lance
`~/nebula/scripts/backup.sh`, la commande de `make backup`. Si la machine
était éteinte à cette heure, la sauvegarde part au démarrage suivant
(`Persistent=true`). Les 14 sauvegardes les plus récentes sont conservées ;
le ménage n'a lieu qu'après une sauvegarde réussie.

- Heure et nombre conservé : `HEURE="*-*-* 03:00:00" GARDER=30 ./cluster/45-sauvegardes.sh`
- Dernière exécution : `journalctl -u nebula-sauvegarde.service`
- Dernière et prochaine sauvegarde : `make status`

Preuve : [preuves/sauvegarde-planifiee.txt](preuves/sauvegarde-planifiee.txt).

## 7. Runner de livraison

Le registry et le manager sont sur un réseau privé : un runner hébergé par
GitHub ne peut pas les joindre. `cluster/50-runner.sh` installe le runner
GitHub Actions sur le manager, en service systemd, hors Swarm :

```bash
REPO=https://github.com/<compte>/<depot> JETON=<jeton> ./cluster/50-runner.sh
```

Le jeton d'enregistrement se lit dans GitHub (Settings > Actions > Runners >
New self-hosted runner). Le script installe aussi les bibliothèques dont le
runner a besoin (`libicu`). Côté GitHub :

- deux secrets du dépôt (Settings > Secrets and variables > Actions),
  `REGISTRY_USER` et `REGISTRY_PASSWORD`, dont les valeurs sont dans
  `~/.nebula/identifiants` sur le manager ;
- un environnement `production` (Settings > Environments), utilisé par le
  workflow de déploiement. On peut y exiger une validation avant exécution.

Le runner n'ouvre que des connexions sortantes vers GitHub : le pare-feu n'a
aucune ouverture pour lui.

Preuve : [preuves/livraison-github-actions.txt](preuves/livraison-github-actions.txt).
