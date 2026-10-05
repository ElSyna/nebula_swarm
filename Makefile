# Commandes d'exploitation de Nebula. A lancer sur le manager, a la racine du
# depot (sauf dev et dev-down, sur un poste de developpement).
SHELL    := /bin/bash
REGISTRY ?= registry.local:5000
export REGISTRY
# TAG n'est exporte que s'il est donne : sans lui, deploy garde la version en service.
ifdef TAG
export TAG
endif

.DEFAULT_GOAL := help
.PHONY: help secrets build deploy status smoke charge logs scale update rollback \
        rebalance backup restore bus exposition drill service destroy dev dev-down

help: ## Affiche cette aide
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-11s\033[0m %s\n",$$1,$$2}'

secrets: ## Cree les secrets Swarm manquants
	./scripts/secrets.sh
build: ## Construit, tague et publie les images       (TAG=v1.1.0, defaut : fichier VERSION)
	./scripts/build-push.sh $(or $(TAG),$(shell cat VERSION))
deploy: ## Deploie ou met a jour edge + nebula         (TAG=v1.1.0, defaut : version en service)
	./scripts/deploy.sh
status: ## Noeuds, services, instances, versions, machines
	./scripts/status.sh
smoke: ## Verifie la chaine applicative complete
	./scripts/smoke.sh
charge: ## Requetes en continu et bilan                (D=60 P=/health/comptes)
	./scripts/charge.sh $(or $(D),60) $(or $(P),/health/comptes)
logs: ## Journaux d'un service                       (S=comptes)
	docker service logs --tail 50 --timestamps nebula_$(or $(S),comptes)
scale: ## Change le nombre d'instances                (S=comptes N=5)
	docker service scale nebula_$(S)=$(N)
rollback: ## Retour arriere d'un service                 (S=comptes)
	docker service rollback nebula_$(S)
rebalance: ## Repartit a nouveau les services sans etat sur les noeuds
	for s in comptes publications worker-medias; do docker service update --quiet --force nebula_$$s; done
backup: ## Sauvegarde la base dans /srv/nebula/backups
	./scripts/backup.sh
restore: ## Restaure la base                            (F=fichier, defaut : la plus recente)
	./scripts/restore.sh $(F)
bus: ## Messages par file, dont la file des erreurs
	./scripts/bus.sh files
exposition: ## Ports qui repondent sur chaque noeud
	./scripts/exposition.sh
drill: ## Version defectueuse puis retour arriere      (S=comptes M=sonde|crash)
	./scripts/drill-rollback.sh $(or $(S),comptes) $(or $(M),sonde)
service: ## Ajoute un service                           (NOM=whoami IMAGE=traefik/whoami:v1.11 PORT=80)
	./scripts/add-service.sh $(NOM) $(IMAGE) $(PORT)
destroy: ## Retire les stacks (volumes et secrets conserves)
	./scripts/destroy.sh

dev: ## Poste de developpement : les 7 services hors Swarm
	docker compose -f compose.dev.yml up --build -d && docker compose -f compose.dev.yml ps
dev-down: ## Arrete l'environnement local
	docker compose -f compose.dev.yml down
