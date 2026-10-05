#!/usr/bin/env bash
# Cree les secrets Swarm attendus par les stacks. A executer sur le manager.
#   ./scripts/secrets.sh
#
# Les valeurs sont tirees au hasard et ne sont ecrites nulle part ailleurs
# que dans le Swarm, sauf le mot de passe d'administration de l'edge : il
# doit etre connu d'un humain, il est donc aussi range dans
# ~/.nebula/identifiants (mode 600, hors depot).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sur_manager

IDENTIFIANTS=${IDENTIFIANTS:-$HOME/.nebula/identifiants}
alea()   { openssl rand -hex 16; }   # hexadecimal : utilisable tel quel dans une URL
existe() { docker secret inspect "$1" >/dev/null 2>&1; }
noter()  { install -d -m 700 "$(dirname "$IDENTIFIANTS")"; touch "$IDENTIFIANTS"; chmod 600 "$IDENTIFIANTS"
           sed -i "/^$1=/d" "$IDENTIFIANTS"; echo "$1=$2" >> "$IDENTIFIANTS"; }

for s in nebula_db_password nebula_cache_password; do
  if existe "$s"; then echo "   $s : deja present"
  else alea | tr -d '\n' | docker secret create "$s" - >/dev/null; echo "   $s : cree"; fi
done

# Le bus a besoin de deux secrets issus du meme mot de passe : le mot de
# passe en clair pour les clients, son empreinte pour le serveur.
if existe nebula_bus_password && existe nebula_bus_definitions; then
  echo "   nebula_bus_password, nebula_bus_definitions : deja presents"
elif existe nebula_bus_password || existe nebula_bus_definitions; then
  erreur "un seul des deux secrets du bus existe : supprimez-le (docker secret rm) et relancez"
else
  mdp=$(alea)
  # Format RabbitMQ : base64( sel + sha256(sel + mot de passe) ), sel de 4 octets.
  empreinte=$(printf '%s' "$mdp" | python3 -c '
import base64, hashlib, os, sys
sel = os.urandom(4)
print(base64.b64encode(sel + hashlib.sha256(sel + sys.stdin.buffer.read()).digest()).decode())')
  printf '%s' "$mdp" | docker secret create nebula_bus_password - >/dev/null
  sed "s|@PASSWORD_HASH@|$empreinte|" "$RACINE/config/bus-definitions.tpl.json" |
    docker secret create nebula_bus_definitions - >/dev/null
  echo "   nebula_bus_password, nebula_bus_definitions : crees"
fi

if existe edge_admin_users; then
  echo "   edge_admin_users : deja present"
else
  mdp=${EDGE_ADMIN_PASSWORD:-$(alea)}
  # Fichier htpasswd, empreinte bcrypt (paquet apache2-utils).
  printf '%s' "$mdp" | htpasswd -niB admin | sed '/^$/d' | docker secret create edge_admin_users - >/dev/null
  noter EDGE_ADMIN_USER admin
  noter EDGE_ADMIN_PASSWORD "$mdp"
  echo "   edge_admin_users : cree (identifiants dans $IDENTIFIANTS)"
fi

echo
docker secret ls --format 'table {{.Name}}\t{{.CreatedAt}}'
