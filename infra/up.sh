#!/usr/bin/env bash
# Prepare et demarre le registry et Portainer, sur le manager, hors Swarm.
#   ./infra/up.sh
# Rejouable : ce qui existe deja (certificats, comptes) est conserve.
# Etat hors depot : /srv/nebula (certificats, htpasswd) et ~/.nebula/identifiants.
set -euo pipefail
cd "$(dirname "$0")"

ETAT=${INFRA_HOME:-/srv/nebula}
NOM=${REGISTRY_HOST:-registry.local}
IP=${REGISTRY_IP:-$(docker info --format '{{.Swarm.NodeAddr}}')}
IDENTIFIANTS=$HOME/.nebula/identifiants
noter() { install -d -m 700 "$(dirname "$IDENTIFIANTS")"; touch "$IDENTIFIANTS"; chmod 600 "$IDENTIFIANTS"
          sed -i "/^$1=/d" "$IDENTIFIANTS"; echo "$1=$2" >> "$IDENTIFIANTS"; }

sudo install -d -o "$USER" -g "$USER" "$ETAT"
mkdir -p "$ETAT"/registry/auth "$ETAT"/registry/certs "$ETAT"/portainer "$ETAT"/backups
chmod 700 "$ETAT"/registry/certs "$ETAT"/portainer

echo "== 1. certificats (autorite locale + certificat du registry)"
C=$ETAT/registry/certs
if [ ! -f "$C/registry.crt" ]; then
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/CN=Nebula CA" \
    -keyout "$C/ca.key" -out "$C/ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$NOM" \
    -keyout "$C/registry.key" -out "$C/registry.csr" 2>/dev/null
  openssl x509 -req -in "$C/registry.csr" -CA "$C/ca.crt" -CAkey "$C/ca.key" -CAcreateserial \
    -days 825 -out "$C/registry.crt" \
    -extfile <(printf 'subjectAltName=DNS:%s,IP:%s\nextendedKeyUsage=serverAuth\n' "$NOM" "$IP") 2>/dev/null
  chmod 600 "$C"/*.key
  echo "   crees pour $NOM ($IP)"
else
  echo "   deja presents"
fi

echo "== 2. compte du registry"
if [ ! -s "$ETAT/registry/auth/htpasswd" ]; then
  mdp=$(openssl rand -hex 16)
  # bcrypt obligatoire : le registry refuse les autres algorithmes.
  printf '%s' "$mdp" | htpasswd -niB nebula | sed '/^$/d' > "$ETAT/registry/auth/htpasswd"
  noter REGISTRY_USER nebula
  noter REGISTRY_PASSWORD "$mdp"
  echo "   cree (identifiants dans $IDENTIFIANTS)"
else
  echo "   deja present"
fi

echo "== 3. mot de passe administrateur de Portainer"
if [ ! -s "$ETAT/portainer/admin_password" ]; then
  mdp=$(openssl rand -hex 12)
  printf '%s' "$mdp" > "$ETAT/portainer/admin_password"
  chmod 600 "$ETAT/portainer/admin_password"
  noter PORTAINER_USER admin
  noter PORTAINER_PASSWORD "$mdp"
  echo "   cree (identifiants dans $IDENTIFIANTS)"
else
  echo "   deja present"
fi

echo "== 4. demarrage"
INFRA_HOME=$ETAT docker compose -f compose.yaml up -d --quiet-pull
docker compose -f compose.yaml ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'

echo "== 5. le manager fait confiance au registry et s'y connecte"
"$(pwd)/trust.sh" "$IP" < "$C/ca.crt"
. "$IDENTIFIANTS"
for _ in $(seq 1 15); do
  printf '%s' "$REGISTRY_PASSWORD" | docker login "$NOM:5000" -u "$REGISTRY_USER" --password-stdin >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS --cacert "$C/ca.crt" -u "$REGISTRY_USER:$REGISTRY_PASSWORD" "https://$NOM:5000/v2/_catalog"
echo "   sans identifiants : HTTP $(curl -s -o /dev/null -w '%{http_code}' --cacert "$C/ca.crt" "https://$NOM:5000/v2/_catalog") (401 attendu)"
