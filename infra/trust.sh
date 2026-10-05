#!/usr/bin/env bash
# Sur un noeud : declare le registry (nom + autorite de certification).
#   ./infra/trust.sh <ip_du_registry> < ca.crt
# Aucun redemarrage du daemon Docker n'est necessaire.
set -euo pipefail
IP=${1:?usage : trust.sh <ip_du_registry> < ca.crt}
NOM=${REGISTRY_HOST:-registry.local}

sudo install -d "/etc/docker/certs.d/$NOM:5000"
sudo tee "/etc/docker/certs.d/$NOM:5000/ca.crt" >/dev/null

# cloud-init reecrit /etc/hosts a chaque demarrage a partir de son modele :
# la ligne doit etre dans les deux fichiers pour survivre a un redemarrage.
for f in /etc/hosts /etc/cloud/templates/hosts.debian.tmpl; do
  [ -f "$f" ] || continue
  sudo sed -i "/[[:space:]]$NOM\$/d" "$f"
  echo "$IP $NOM" | sudo tee -a "$f" >/dev/null
done
echo "   $(hostname) : $NOM -> $IP, autorite installee"
