#!/bin/bash
# Prep this Ubuntu arm64 VM as a kubeadm worker (mirrors the old mac-m1-worker /
# ubuntu-26-desktop-node recipe: swap/zram off, rbd+br_netfilter+overlay modules,
# nfs-common, containerd with SystemdCgroup, kube* pinned to cluster version 1.35.6).
set -euxo pipefail

K8S_MINOR=v1.35
K8S_VER=1.35.6

# --- swap / zram off ---
swapoff -a || true
sed -i.bak '/\sswap\s/d' /etc/fstab
systemctl stop zramswap.service 2>/dev/null || true
systemctl disable zramswap.service 2>/dev/null || true
apt-get remove -y zram-config 2>/dev/null || true

# --- kernel modules + sysctls ---
printf 'rbd\nbr_netfilter\noverlay\n' > /etc/modules-load.d/k8s.conf
modprobe rbd br_netfilter overlay
printf 'net.ipv4.ip_forward=1\nnet.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\n' > /etc/sysctl.d/99-k8s.conf
sysctl --system >/dev/null

# --- base packages ---
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nfs-common containerd apt-transport-https ca-certificates curl gpg

# --- containerd: SystemdCgroup=true ---
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# --- kubeadm/kubelet/kubectl from pkgs.k8s.io, pinned ---
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
PKG_VER=$(apt-cache madison kubeadm | awk -v v="$K8S_VER" '$3 ~ v {print $3; exit}')
[ -n "$PKG_VER" ] || { echo "ERROR: kubeadm $K8S_VER not found in $K8S_MINOR repo"; exit 1; }
apt-get install -y kubelet="$PKG_VER" kubeadm="$PKG_VER" kubectl="$PKG_VER"
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

echo "PREP OK: $(kubeadm version -o short), containerd $(containerd --version | awk '{print $3}'), swap: $(swapon --show | wc -l) entries"
