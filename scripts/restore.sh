#!/usr/bin/env bash
# Restaure la base depuis une sauvegarde. A executer sur le manager.
#   ./scripts/restore.sh [fichier]      defaut : la sauvegarde la plus recente
#
# Les tables sont supprimees puis recreees a partir du fichier, dans une
# seule transaction : en cas d'erreur, la base reste dans son etat d'avant.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sur_manager

DEST=${BACKUP_DIR:-/srv/nebula/backups}
FICHIER=${1:-$(ls -1t "$DEST"/nebula-*.dump 2>/dev/null | head -1)}
[ -n "$FICHIER" ] && [ -f "$FICHIER" ] || erreur "aucune sauvegarde trouvee dans $DEST"
NOM=$(basename "$FICHIER")
DOSSIER=$(cd "$(dirname "$FICHIER")" && pwd)

titre "restauration de $DOSSIER/$NOM"
job nebula_restore \
  --network nebula_internal \
  --secret source=nebula_db_password,target=db_password \
  --constraint "node.hostname==$(docker info --format '{{.Name}}')" \
  --mount "type=bind,source=$DOSSIER,target=/backups,readonly" \
  --limit-memory 256M \
  "$REGISTRY/mirror/postgres:18-alpine" sh -ec '
    export PGPASSWORD=$(cat /run/secrets/db_password)
    pg_restore -h db -U nebula -d nebula --clean --if-exists --no-owner --single-transaction /backups/'"$NOM"'
    echo "   comptes : $(psql -h db -U nebula -d nebula -Atc "select count(*) from comptes")"
    echo "   publications : $(psql -h db -U nebula -d nebula -Atc "select count(*) from publications")"
  ' || erreur "la restauration a echoue"
echo "   restauration terminee (le cache du fil expire en 30 s)"
