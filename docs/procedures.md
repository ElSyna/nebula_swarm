# Procédures d'exploitation

Sauf mention contraire, les commandes se lancent **sur le manager, dans
`~/nebula`** (`ssh manager`, puis `cd ~/nebula`). « poste » désigne le poste
d'administration, à la racine du dépôt. `make help` liste les commandes.

## 1. Déploiement initial

Le cluster est construit ([cluster.md](cluster.md)) et rien n'est déployé.

1. poste : `./cluster/30-depot.sh` dépose le dépôt sur le manager.
2. `make secrets` crée les secrets manquants (rien à saisir).
3. `make build TAG=v1.0.0` seulement si cette version n'est pas déjà dans le registry.
4. `make deploy TAG=v1.0.0` déploie l'edge puis Nebula et attend la convergence (30 s).
5. `make smoke` : toutes les lignes doivent être `OK`.
6. `make status` : trois nœuds `Ready`, sept services au complet.

## 2. Mise à jour

1. poste : `git tag v1.1.0 && git push origin main v1.1.0`. La CI construit, analyse et publie les images.
   Sans la CI : `make build TAG=v1.1.0` sur le manager.
2. Facultatif, dans un second terminal : `make charge D=120` émet des requêtes pendant la mise à jour.
3. `make deploy TAG=v1.1.0`, ou GitHub > Actions > CD > Run workflow avec `v1.1.0`.
4. Le script se termine par l'état du cluster : toutes les instances sont en `v1.1.0`.
5. S'il s'arrête sur « retour arriere effectue », Swarm a refusé la version : voir la procédure 3.

## 3. Retour arrière

Automatique : si une tâche de la nouvelle version n'est pas saine, Swarm
ramène seul le service à la version précédente. Il n'y a rien à lancer.

1. Constat : `docker service inspect nebula_comptes --format '{{.UpdateStatus.State}} : {{.UpdateStatus.Message}}'`
2. Cause : `make logs S=comptes`, et `docker service ps nebula_comptes --no-trunc` (colonne ERROR).

Manuel, quand la version tourne mais se comporte mal :

3. `make deploy TAG=v1.0.0` remet la version précédente sur les trois services, sans interruption.
4. `make smoke`.

Pour un seul service, immédiatement : `make rollback S=comptes`. Une seule
fois : un second appel remettrait la version retirée.

## 4. Arrêt et redémarrage du cluster

1. poste : `./cluster/90-arret.sh` arrête worker1, worker2, puis le manager.
2. Proxmox : démarrer les trois machines, le manager en premier.
3. Attendre deux à trois minutes. Docker démarre avec chaque machine, le Swarm se
   reforme, le manager relance les services ; les applications réessaient
   jusqu'à ce que la base et le bus répondent.
4. `make status` : trois nœuds `Ready`, sept services au complet.
5. `make smoke` : la chaîne répond, les données sont là.
6. Seulement si `make status` montre toutes les instances d'un service sur un même nœud : `make rebalance`.

## 5. Restauration des données

Sauvegarder (avant chaque mise à jour, et régulièrement) : `make backup`
écrit un fichier dans `/srv/nebula/backups/` sur le manager.

1. `ls -lt /srv/nebula/backups/` : choisir la sauvegarde.
2. `make restore` restaure la plus récente ; `make restore F=/srv/nebula/backups/<fichier>` une autre.
3. Le script affiche le nombre de comptes et de publications restaurés.
4. `make smoke`.

Si le volume de la base est perdu, la base redémarre vide (schéma créé par
`db/init.sql`) : la procédure est la même.
