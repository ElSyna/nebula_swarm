#!/usr/bin/env bash
# Installe Docker Engine sur les trois machines. A lancer depuis le poste.
#   ./cluster/10-docker.sh
# Rejouable : une machine deja equipee n'est pas modifiee.
set -euo pipefail
cd "$(dirname "$0")"; . ./nodes.env

for n in $MANAGER $WORKERS; do
  echo "===== $n"
  ssh "$n" bash -se <<'NOEUD'
set -euo pipefail
if ! command -v docker >/dev/null; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
fi
# Outils utilises par les scripts d'exploitation.
command -v make >/dev/null && command -v git >/dev/null && command -v nc >/dev/null && command -v htpasswd >/dev/null ||
  { sudo apt-get update -qq; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq make git netcat-openbsd apache2-utils; }

# Journaux des conteneurs bornes : sans cela ils remplissent le disque.
if [ ! -f /etc/docker/daemon.json ]; then
  echo '{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }' |
    sudo tee /etc/docker/daemon.json >/dev/null
  sudo systemctl restart docker
fi
# Docker demarre avec la machine : c'est ce qui reforme le cluster tout seul.
sudo systemctl enable --quiet docker containerd
echo "   $(hostname) : $(sudo docker version --format 'Docker {{.Server.Version}}'), demarrage automatique $(systemctl is-enabled docker)"
NOEUD
done
