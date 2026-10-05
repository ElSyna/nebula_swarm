#!/usr/bin/env bash
# Installe le runner GitHub Actions sur le manager, hors Swarm, en service
# systemd. A lancer depuis le poste.
#   REPO=https://github.com/<compte>/<depot> JETON=<jeton> ./cluster/50-runner.sh
#
# Le jeton d'enregistrement se lit dans GitHub : Settings > Actions > Runners
# > New self-hosted runner. Il expire au bout d'une heure et ne sert qu'a
# l'enregistrement : il n'est ecrit nulle part.
set -euo pipefail
cd "$(dirname "$0")"; . ./nodes.env
: "${REPO:?definir REPO=https://github.com/compte/depot}" "${JETON:?definir JETON (jeton du runner)}"

ssh "$MANAGER" REPO="$REPO" JETON="$JETON" bash -se <<'NOEUD'
set -euo pipefail
mkdir -p ~/actions-runner && cd ~/actions-runner
if [ ! -x ./config.sh ]; then
  v=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
  curl -fsSL -o runner.tgz "https://github.com/actions/runner/releases/download/v$v/actions-runner-linux-x64-$v.tar.gz"
  tar xzf runner.tgz && rm runner.tgz
fi
[ -f .runner ] || ./config.sh --unattended --url "$REPO" --token "$JETON" --name "$(hostname)" --labels nebula --replace
sudo ./svc.sh install "$USER" >/dev/null 2>&1 || true
sudo ./svc.sh start >/dev/null
sudo ./svc.sh status | grep -E 'Active|Loaded' | sed 's/^ */   /'
NOEUD
