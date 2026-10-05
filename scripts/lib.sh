# Variables et fonctions communes aux scripts d'exploitation.
# Charge par :  . "$(dirname "$0")/lib.sh"

RACINE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REGISTRY=${REGISTRY:-registry.local:5000}
STACK=nebula
SERVICES_APP="comptes publications worker-medias"
BASE_URL=${BASE_URL:-http://127.0.0.1}

titre()  { printf '\n== %s\n' "$*"; }
erreur() { echo "ERREUR : $*" >&2; exit 1; }

sur_manager() {
  [ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" = true ] ||
    erreur "a executer sur le manager du Swarm"
}

# job <nom> <options et image de docker service create>
# Lance une tache ponctuelle Swarm (replicated-job), attend sa fin, affiche
# ses journaux, la supprime. Code de retour 0 si la tache s'est terminee.
job() {
  local nom=$1 etat=""; shift
  docker service rm "$nom" >/dev/null 2>&1 || true
  docker service create --detach --quiet --with-registry-auth --name "$nom" \
    --mode replicated-job --restart-condition none "$@" >/dev/null
  for _ in $(seq 1 150); do
    etat=$(docker service ps "$nom" --format '{{.CurrentState}}' | head -1)
    case "$etat" in Complete*|Failed*|Rejected*) break ;; esac
    sleep 2
  done
  docker service logs --raw "$nom" 2>&1 || true
  case "$etat" in
    Complete*) docker service rm "$nom" >/dev/null; return 0 ;;
    *) docker service ps "$nom" --no-trunc --format '   {{.CurrentState}} {{.Error}}'
       docker service rm "$nom" >/dev/null; return 1 ;;
  esac
}
