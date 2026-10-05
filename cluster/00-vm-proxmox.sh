#!/usr/bin/env bash
# Cree les trois machines virtuelles sur l'hote Proxmox VE, a partir de
# l'image cloud Debian 13. A lancer sur l'hote Proxmox, en root.
#   CLE=/root/poste.pub ./00-vm-proxmox.sh
#
# A adapter a l'hote : identifiants de VM, stockage, reseau.
set -euo pipefail

STOCKAGE=${STOCKAGE:-local-lvm}
PONT=${PONT:-vn1021}                 # reseau des VM (vnet SDN)
PASSERELLE=${PASSERELLE:-10.96.253.254}
CLE=${CLE:?CLE=chemin de la cle publique SSH du poste d'administration}
IMAGE=debian-13-genericcloud-amd64.qcow2

[ -f "$IMAGE" ] || wget -q "https://cloud.debian.org/images/cloud/trixie/latest/$IMAGE"

#        id   nom      adresse         memoire(Mo) disque(Go)
creer() {
  local id=$1 nom=$2 ip=$3 mem=$4 disque=$5
  qm create "$id" --name "$nom" --cores 2 --memory "$mem" --net0 "virtio,bridge=$PONT" \
    --scsihw virtio-scsi-pci --serial0 socket --vga serial0 --agent 1 --onboot 1
  qm set "$id" --virtio0 "$STOCKAGE:0,import-from=$PWD/$IMAGE"
  qm resize "$id" virtio0 "${disque}G"
  # Disque cloud-init : nom d'hote, utilisateur, cle SSH et adresse FIXE.
  # Une adresse qui changerait au redemarrage empecherait le cluster de se reformer.
  qm set "$id" --ide2 "$STOCKAGE:cloudinit" --boot order=virtio0 \
    --ciuser ubuntu --sshkeys "$CLE" \
    --ipconfig0 "ip=$ip/24,gw=$PASSERELLE" --nameserver "$PASSERELLE"
  qm start "$id"
}

creer 211 manager 10.96.253.211 4096 32
creer 212 worker1 10.96.253.212 4096 32
creer 213 worker2 10.96.253.213 2048 20
