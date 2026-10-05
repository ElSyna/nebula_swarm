#!/usr/bin/env bash
# Arrete proprement les trois machines, l'une apres l'autre : les workers
# d'abord, le manager en dernier. A lancer depuis le poste.
#   ./cluster/90-arret.sh            arret
#   ./cluster/90-arret.sh reboot     redemarrage (meme ordre)
# Rallumage : demarrer les trois VM (le manager en premier si possible).
# Rien d'autre a faire : voir docs/procedures.md, "Arret et redemarrage".
set -euo pipefail
cd "$(dirname "$0")"; . ./nodes.env
ACTION=${1:-poweroff}

for n in $WORKERS $MANAGER; do
  echo "== $ACTION de $n"
  # systemd arrete Docker, qui laisse a chaque conteneur son delai d'arret
  # (stop_grace_period) : la base termine proprement.
  ssh "$n" "sudo systemctl $ACTION" || true
  sleep 5
done
