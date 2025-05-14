#!/usr/bin/env bash
# 🛡️ Setup seguro de servidor Ubuntu 24.04 com Docker, otimizações e hardening
# Requisitos: rodar como root (sudo) e definir as variáveis abaixo

set -euo pipefail
IFS=$'\n\t'

#####################
# VARIÁVEIS INICIAIS
#####################
SSH_PUB_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGB5Rw31s1I3ba0HPfVN0wjZVvzAQ2/4t4UiV368gyIf gomes7296@gmail.com"  # <- Substitua pela sua chave
TIMEZONE="UTC"
SERVER_USER="$(logname)"  # Usuário logado que rodou o sudo

#####################
# 1. CHECAGENS
#####################
[[ $EUID -eq 0 ]] || { echo "❌ Rode como root (use sudo)."; exit 1; }

echo "🔐 Iniciando configuração para o usuário: $SERVER_USER"
sleep 1

#####################
# 2. ATUALIZA SISTEMA E TIMEZONE
#####################
echo "📦 Atualizando sistema e configurando timezone..."
apt update -y && apt full-upgrade -y && apt autoremove -y && apt clean
ln -snf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && dpkg-reconfigure -f noninteractive tzdata

#####################
# 2.1. SWAP (4 GiB)
#####################
echo "💾 Criando e ativando swapfile (2 GiB)…"

if ! grep -q '/swapfile' /etc/fstab; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "vm.swappiness=10" > /etc/sysctl.d/60-swap.conf
fi

#####################
# 3. OPENSSH + CHAVE
#####################
echo "🔑 Garantindo servidor SSH ativo e chave pública configurada..."
apt install -y openssh-server
systemctl enable --now ssh

if [ -n "$SSH_PUB_KEY" ]; then
  mkdir -p /home/$SERVER_USER/.ssh
  touch /home/$SERVER_USER/.ssh/authorized_keys
  if ! grep -qxF "$SSH_PUB_KEY" /home/$SERVER_USER/.ssh/authorized_keys; then
    echo "$SSH_PUB_KEY" >> /home/$SERVER_USER/.ssh/authorized_keys
  fi
  chmod 700 /home/$SERVER_USER/.ssh
  chmod 600 /home/$SERVER_USER/.ssh/authorized_keys
  chown -R $SERVER_USER:$SERVER_USER /home/$SERVER_USER/.ssh
fi

#####################
# 4. HARDENING SSH
#####################
echo "🛡️ Endurecendo configuração do SSH..."
cp /etc/ssh/sshd_config{,.bak.$(date +%F)}
sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -ri 's/^#?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
grep -q '^MaxAuthTries' /etc/ssh/sshd_config || echo 'MaxAuthTries 3' >> /etc/ssh/sshd_config
grep -q '^MaxStartups' /etc/ssh/sshd_config || echo 'MaxStartups 10:30:60' >> /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd

#####################
# 5. FIREWALL (UFW)
#####################
echo "🔥 Configurando firewall com UFW..."
apt install -y ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment "OpenSSH"
ufw allow 80,443/tcp comment "HTTP/S - Traefik"
# ufw allow 5432/tcp  comment "PostgreSQL"
# ufw allow 5672/tcp  comment "AMQP (RabbitMQ)"
# ufw allow 6379/tcp  comment "Redis"
# ufw allow 15672/tcp comment "RabbitMQ UI (opcional)"
ufw --force enable

#####################
# 6. FAIL2BAN
#####################
echo "🚨 Instalando e configurando Fail2Ban..."
apt install -y fail2ban
cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime  = 1h
EOF
systemctl enable --now fail2ban

#####################
# 7. DOCKER + COMPOSE
#####################
echo "🐳 Instalando Docker Engine e Docker Compose v2..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
   https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "$SERVER_USER"
systemctl enable --now docker

#####################
# 8. HARDENING DOCKER
#####################
echo "🔒 Configurando daemon do Docker (logrotate e iptables)..."
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "iptables": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
EOF
systemctl restart docker

#####################
# 9. WATCHTOWER
#####################
echo "📡 Instalando Watchtower para auto-update dos containers..."
docker run -d \
  --name watchtower \
  --restart always \
  -e WATCHTOWER_CLEANUP=true \
  -e WATCHTOWER_POLL_INTERVAL=21600 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower

#####################
# 10. SYSCTL & KERNEL TWEAKS
#####################
echo "⚙️ Aplicando otimizações no kernel..."
cat >/etc/sysctl.d/99-custom.conf <<'EOF'
fs.inotify.max_user_watches=524288
net.core.somaxconn=1024
vm.swappiness=10
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_fin_timeout=15
EOF
sysctl --system

#####################
# FINALIZAÇÃO
#####################
echo -e "\n✅ Servidor pronto!"
echo "🔁 Faça logout e login novamente para aplicar o grupo docker ao usuário."
echo "📂 Após isso, copie seus arquivos e rode: docker compose up -d"
