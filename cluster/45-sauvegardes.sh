#!/usr/bin/env bash
# Planifie la sauvegarde quotidienne de la base, sur le manager, par un
# minuteur systemd (hors Swarm). A lancer depuis le poste, apres 30-depot.sh.
#   ./cluster/45-sauvegardes.sh
#   HEURE="*-*-* 03:00:00" GARDER=30 ./cluster/45-sauvegardes.sh
#
# Le minuteur lance ~/nebula/scripts/backup.sh : la meme commande que
# make backup. Les machines sont a l'heure UTC.
set -euo pipefail
cd "$(dirname "$0")"; . ./nodes.env
HEURE=${HEURE:-*-*-* 02:30:00}
GARDER=${GARDER:-14}

ssh "$MANAGER" HEURE="'$HEURE'" GARDER="$GARDER" bash -se <<'NOEUD'
set -euo pipefail
systemd-analyze calendar "$HEURE" >/dev/null   # refuse une heure mal ecrite

sudo tee /etc/systemd/system/nebula-sauvegarde.service >/dev/null <<UNITE
[Unit]
Description=Sauvegarde de la base Nebula
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
User=$USER
WorkingDirectory=$HOME/nebula
Environment=BACKUP_KEEP=$GARDER
ExecStart=$HOME/nebula/scripts/backup.sh
UNITE

sudo tee /etc/systemd/system/nebula-sauvegarde.timer >/dev/null <<UNITE
[Unit]
Description=Sauvegarde quotidienne de la base Nebula

[Timer]
OnCalendar=$HEURE
# Si la machine etait eteinte a l'heure prevue, la sauvegarde est lancee
# au demarrage suivant.
Persistent=true

[Install]
WantedBy=timers.target
UNITE

sudo systemctl daemon-reload
sudo systemctl enable --quiet --now nebula-sauvegarde.timer
systemctl list-timers nebula-sauvegarde.timer --no-pager | sed -n '1,2p'
echo "   $GARDER sauvegardes conservees dans /srv/nebula/backups"
NOEUD
