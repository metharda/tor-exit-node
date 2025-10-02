#!/bin/bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y cloud-init

if ! id "${username}" &>/dev/null; then
	useradd -m -s /bin/bash "${username}"
	echo "${username}:${password}" | chpasswd
	usermod -aG sudo "${username}"

	echo "${username} ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/90-${username}"
	chmod 440 "/etc/sudoers.d/90-${username}"
fi

mkdir -p "/home/${username}/.ssh"
chmod 700 "/home/${username}/.ssh"
chown "${username}:${username}" "/home/${username}/.ssh"

systemctl enable ssh
systemctl start ssh

apt-get install -y curl wget gnupg software-properties-common

echo "User setup completed for ${username}" >>/var/log/user-data.log
