#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "Updating package lists..."
sudo apt update

echo "Installing common admin tools..."
sudo apt install -y \
  curl \
  wget \
  git \
  vim \
  nano \
  tmux \
  screen \
  htop \
  btop \
  tree \
  ncdu \
  jq \
  unzip \
  zip \
  p7zip-full \
  rsync \
  openssh-client \
  openssh-server \
  ca-certificates \
  gnupg \
  software-properties-common \
  apt-transport-https \
  bash-completion \
  lsb-release \
  file \
  less \
  xz-utils \
  whois \
  dnsutils \
  iputils-ping \
  traceroute \
  mtr-tiny \
  nmap \
  net-tools \
  tcpdump \
  lsof \
  strace \
  ethtool \
  iperf3 \
  ufw \
  smartmontools \
  lm-sensors \
  nvme-cli \
  pciutils \
  usbutils \
  acl \
  python3 \
  python3-pip \
  python3-venv

echo "Enabling SSH service..."
sudo systemctl enable ssh
sudo systemctl start ssh

echo "Optional: enable UFW and allow SSH"
echo "Run these if you want firewall enabled:"
echo "  sudo ufw allow OpenSSH"
echo "  sudo ufw enable"

echo "Done."