#!/usr/bin/env bash
# Sauvegarde la base dans un fichier, sur le manager. A executer sur le manager.
#   ./scripts/backup.sh
#
# La base tourne sur le noeud tier=data. Une tache ponctuelle Swarm, placee
# sur le manager et branchee sur le reseau interne, execute pg_dump : la
# sauvegarde est ainsi rangee sur une autre machine que la base.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sur_manager

DEST=${BACKUP_DIR:-/srv/nebula/backups}
FICHIER=nebula-$(date -u +%Y%m%dT%H%M%SZ).dump
mkdir -p "$DEST"

titre "sauvegarde de la base vers $DEST/$FICHIER"
job nebula_backup \
  --network nebula_internal \
  --secret source=nebula_db_password,target=db_password \
  --constraint "node.hostname==$(docker info --format '{{.Name}}')" \
  --mount "type=bind,source=$DEST,target=/backups" \
  --limit-memory 256M \
  "$REGISTRY/mirror/postgres:18-alpine" sh -ec '
    export PGPASSWORD=$(cat /run/secrets/db_password)
    pg_dump -h db -U nebula -d nebula -Fc -f /backups/'"$FICHIER"'
    echo "   tables : $(pg_restore --list /backups/'"$FICHIER"' | grep -c "TABLE DATA")"
    echo "   comptes : $(psql -h db -U nebula -d nebula -Atc "select count(*) from comptes")"
    echo "   publications : $(psql -h db -U nebula -d nebula -Atc "select count(*) from publications")"
  ' || erreur "la sauvegarde a echoue"

ls -lh "$DEST/$FICHIER"
