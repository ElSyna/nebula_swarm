#!/usr/bin/env bash
# Pare-feu des trois machines : tout est ferme par defaut, seules les
# ouvertures de la matrice de flux (docs/cluster.md) sont posees, et elles
# ont un sens. A lancer depuis le poste.
#   ./cluster/25-parefeu.sh           pose les regles, noeud par noeud
#   ./cluster/25-parefeu.sh verif     verifie les ouvertures et les refus
#   ./cluster/25-parefeu.sh regles    affiche les regles de chaque noeud
#   ./cluster/25-parefeu.sh off       retire le pare-feu (depannage)
#
# Les regles vivent dans une table nftables a part (inet nebula), chargee au
# demarrage par le service nebula-parefeu avant Docker. Les tables gerees
# par Docker ne sont pas touchees.
set -euo pipefail
cd "$(dirname "$0")"; . ./nodes.env
ip() { local v="IP_$1"; echo "${!v}"; }
virgules() { local s="" n; for n in "$@"; do s="$s${s:+, }$(ip "$n")"; done; echo "$s"; }
TOUS="$MANAGER $WORKERS"

regles() {   # regles <noeud> : le jeu de regles nftables de ce noeud
  local n=$1 app=0 data=0 mgr=0
  [ "$n" = "$NOEUD_DATA" ] && data=1 || app=1
  [ "$n" = "$MANAGER" ] && mgr=1
  cat <<NFT
# Pare-feu de $n. Genere par cluster/25-parefeu.sh : ne pas modifier ici.
table inet nebula
delete table inet nebula

table inet nebula {
  set noeuds { type ipv4_addr; elements = { $(virgules $TOUS) } }
  set app    { type ipv4_addr; elements = { $(virgules $NOEUDS_APP) } }

  # Ports publies par Docker (edge, registry). Docker les redirige vers ses
  # conteneurs avant la chaine "entree" : on les filtre donc ici, plus tot.
  chain publie {
    type filter hook prerouting priority -150; policy accept;
NFT
  [ $data = 1 ] && echo '    iifname "eth0" tcp dport 80 counter drop comment "le noeud de donnees ne sert pas le trafic public"'
  [ $mgr = 1 ]  && echo '    iifname "eth0" tcp dport 5000 ip saddr != @noeuds counter drop comment "registry : reserve aux noeuds du cluster"'
  cat <<NFT
  }

  # Ce que la machine accepte de recevoir. Tout le reste est refuse.
  chain entree {
    type filter hook input priority 0; policy drop;
    ct state established,related accept comment "reponses aux connexions deja ouvertes"
    ct state invalid drop
    iifname "lo" accept
    meta l4proto icmp icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } accept
    meta l4proto ipv6-icmp icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept

    ip saddr $ADMIN_SRC tcp dport 22 accept comment "SSH : depuis le routeur uniquement"
NFT
  [ $app = 1 ] && echo '    tcp dport 80 accept comment "edge : seul port public"'
  [ $mgr = 1 ] && echo '    ip saddr @noeuds tcp dport { 2377, 5000 } accept comment "administration du Swarm et registry : workers -> manager"'
  cat <<NFT
    ip saddr @noeuds tcp dport 7946 accept comment "decouverte entre noeuds"
    ip saddr @noeuds udp dport 7946 accept comment "decouverte entre noeuds"

    # Reseau overlay (VXLAN). Le transport est symetrique, mais on regarde
    # dans le paquet encapsule qui OUVRE la connexion (SYN sans ACK).
NFT
  if [ $data = 1 ]; then
    echo "    ip saddr @app udp dport 4789 vxlan tcp flags & (syn | ack) == syn vxlan tcp dport != { $PORTS_DATA } counter drop comment \"les noeuds applicatifs n'ouvrent que vers la base et le bus\""
  else
    echo "    ip saddr $(ip "$NOEUD_DATA") udp dport 4789 vxlan tcp flags & (syn | ack) == syn counter drop comment \"le noeud de donnees n'ouvre aucune connexion vers les noeuds applicatifs\""
  fi
  cat <<NFT
    ip saddr @noeuds udp dport 4789 accept comment "reseau overlay entre noeuds"

    counter comment "refuse par defaut"
  }
}
NFT
}

UNITE='[Unit]
Description=Pare-feu Nebula (table nftables inet nebula)
Wants=network-pre.target
Before=network-pre.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nebula/parefeu.nft
ExecReload=/usr/sbin/nft -f /etc/nebula/parefeu.nft
ExecStop=/usr/sbin/nft delete table inet nebula

[Install]
WantedBy=multi-user.target'

poser() {
  local n
  for n in $WORKERS $MANAGER; do
    echo "== $n"
    regles "$n" | ssh "$n" 'sudo install -d -m 755 /etc/nebula && sudo tee /etc/nebula/parefeu.nft >/dev/null && sudo nft -c -f /etc/nebula/parefeu.nft'
    # Filet de securite : si la nouvelle regle nous coupe l'acces, la table
    # est retiree toute seule au bout de 3 minutes.
    ssh "$n" 'sudo systemctl stop nebula-parefeu-secours.timer 2>/dev/null; sudo systemctl reset-failed nebula-parefeu-secours.service 2>/dev/null
      sudo systemd-run --quiet --on-active=180 --unit=nebula-parefeu-secours /usr/sbin/nft delete table inet nebula
      sudo nft -f /etc/nebula/parefeu.nft'
    # Une NOUVELLE connexion SSH doit passer avant de rendre les regles durables.
    if ssh -o ConnectTimeout=10 "$n" true; then
      printf '%s\n' "$UNITE" | ssh "$n" 'sudo systemctl stop nebula-parefeu-secours.timer
        sudo tee /etc/systemd/system/nebula-parefeu.service >/dev/null
        sudo systemctl daemon-reload && sudo systemctl enable --quiet --now nebula-parefeu.service
        echo "   regles posees et chargees au demarrage ($(systemctl is-enabled nebula-parefeu.service))"'
    else
      echo "   !! acces SSH perdu : les regles seront retirees automatiquement dans 3 minutes" >&2
      exit 1
    fi
  done
}

retirer() {
  local n
  for n in $TOUS; do
    ssh "$n" 'sudo systemctl disable --quiet --now nebula-parefeu.service 2>/dev/null; sudo nft delete table inet nebula 2>/dev/null; echo "   $(hostname) : pare-feu retire"'
  done
}

# sonde <vue> <cible> <port> : ouvert ou ferme, vu depuis le routeur
# (connexion TCP ouverte par le routeur, sans y lancer de commande) ou
# depuis un noeud.
sonde() {
  if [ "$1" = "$BASTION" ]; then
    perl -e 'alarm 5; exec @ARGV' ssh -o BatchMode=yes -W "$2:$3" "$BASTION" </dev/null >/dev/null 2>&1 && echo ouvert || echo ferme
  else
    ssh "$1" "nc -z -w 3 $2 $3 2>/dev/null && echo ouvert || echo ferme"
  fi
}
attendu() {  # attendu <libelle> <resultat> <valeur attendue>
  local ok="OK"; [ "$2" = "$3" ] || { ok="ECART (attendu : $3)"; ECARTS=$((ECARTS + 1)); }
  printf '   %-58s %-7s %s\n' "$1" "$2" "$ok"
}
# Une image deja presente sur le noeud, designee par son identifiant : les
# workers n'ont pas d'identifiants de registry et ne peuvent rien tirer.
image() { ssh "$1" "docker image ls --format '{{.ID}} {{.Repository}}' | awk '/mirror\/(postgres|redis|rabbitmq)/ {print \$1; exit}'"; }
dans_overlay() {  # dans_overlay <noeud> <cible> <port> : test depuis un conteneur du reseau interne
  ssh "$1" "docker run --rm --network nebula_internal $(image "$1") sh -c 'nc -z -w 3 $2 $3' >/dev/null 2>&1 && echo ouvert || echo ferme"
}

verifier() {
  ECARTS=0
  local m w d a
  m=$(ip "$MANAGER"); d=$(ip "$NOEUD_DATA")
  for a in $NOEUDS_APP; do [ "$a" != "$MANAGER" ] && w=$a; done

  echo "== 1. depuis l'exterieur du cluster (le routeur $ADMIN_SRC)"
  for n in $TOUS; do
    attendu "routeur -> $n : 22 (SSH)" "$(sonde "$BASTION" "$(ip "$n")" 22)" ouvert
    if [ "$n" = "$NOEUD_DATA" ]; then
      attendu "routeur -> $n : 80 (edge)" "$(sonde "$BASTION" "$(ip "$n")" 80)" ferme
    else
      attendu "routeur -> $n : 80 (edge)" "$(sonde "$BASTION" "$(ip "$n")" 80)" ouvert
    fi
    attendu "routeur -> $n : 7946 (decouverte)" "$(sonde "$BASTION" "$(ip "$n")" 7946)" ferme
  done
  attendu "routeur -> $MANAGER : 2377 (administration du Swarm)" "$(sonde "$BASTION" "$m" 2377)" ferme
  attendu "routeur -> $MANAGER : 5000 (registry)" "$(sonde "$BASTION" "$m" 5000)" ferme

  echo "== 2. entre les machines : un sens, pas l'autre"
  for n in $WORKERS; do
    attendu "$n -> $MANAGER : 2377 (administration du Swarm)" "$(sonde "$n" "$m" 2377)" ouvert
    attendu "$n -> $MANAGER : 5000 (registry)" "$(sonde "$n" "$m" 5000)" ouvert
    attendu "$MANAGER -> $n : 22 (SSH)" "$(sonde "$MANAGER" "$(ip "$n")" 22)" ferme
  done
  attendu "$w -> $NOEUD_DATA : 7946 (decouverte)" "$(sonde "$w" "$d" 7946)" ouvert
  attendu "$NOEUD_DATA -> $w : 7946 (decouverte)" "$(sonde "$NOEUD_DATA" "$(ip "$w")" 7946)" ouvert

  echo "== 3. dans le reseau overlay : applicatif -> donnees, jamais l'inverse"
  attendu "conteneur sur $w -> db : 5432" "$(dans_overlay "$w" db 5432)" ouvert
  attendu "conteneur sur $w -> bus : 5672" "$(dans_overlay "$w" bus 5672)" ouvert
  attendu "conteneur sur $w -> bus : 4369 (port non prevu)" "$(dans_overlay "$w" bus 4369)" ferme
  attendu "conteneur sur $NOEUD_DATA -> comptes : 3000" "$(dans_overlay "$NOEUD_DATA" comptes 3000)" ferme
  attendu "conteneur sur $NOEUD_DATA -> cache : 6379" "$(dans_overlay "$NOEUD_DATA" cache 6379)" ferme

  echo "== 4. paquets refuses, par regle"
  for n in $TOUS; do
    ssh "$n" "sudo nft list table inet nebula | grep -E 'counter packets [0-9]+ bytes [0-9]+ (drop|comment)' | sed -E 's/.*counter packets ([0-9]+) bytes [0-9]+ (drop )?comment \"(.*)\"/   $n : \1 paquets, \3/'"
  done
  echo
  [ "$ECARTS" = 0 ] && echo "aucun ecart avec la matrice de flux" || { echo "$ECARTS ecart(s) avec la matrice de flux"; exit 1; }
}

case "${1:-poser}" in
  poser)  poser ;;
  verif)  verifier ;;
  regles) for n in $TOUS; do regles "$n"; echo; done ;;
  off)    retirer ;;
  *) echo "usage : 25-parefeu.sh [poser|verif|regles|off]" >&2; exit 1 ;;
esac
