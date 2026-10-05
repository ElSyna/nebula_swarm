#!/usr/bin/env bash
# Depose le depot sur le manager (~/nebula). A lancer depuis le poste.
#   ./cluster/30-depot.sh
# Le manager recoit les commits par git push : pas de copie de fichiers a la
# main, et le commit en place sur le manager est toujours identifiable.
set -euo pipefail
cd "$(dirname "$0")/.."; . cluster/nodes.env

ssh "$MANAGER" 'git init -q -b main ~/nebula 2>/dev/null || true
  git -C ~/nebula config receive.denyCurrentBranch updateInstead'
git remote get-url cluster >/dev/null 2>&1 || git remote add cluster "$MANAGER:nebula"
git push --tags cluster main
ssh "$MANAGER" 'git -C ~/nebula log --oneline -1'
