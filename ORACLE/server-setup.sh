#!/usr/bin/env bash
# 🛡️ Setup seguro de servidor Ubuntu 24.04 com Docker, otimizações e hardening
# Requisitos: rodar como root (sudo) e definir as variáveis abaixo

set -euo pipefail
IFS=$'\n\t'

#####################
# VARIÁVEIS INICIAIS
#####################
SSH_PUB_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGB5Rw31s1I3ba0HPfVN0wjZVvzAQ2/4t4UiV368gyIf gomes7296@gmail.com"
TIMEZONE="UTC"
SERVER_USER="$(logname)"
RETRY_COUNT=3
RETRY_DELAY=5

#####################
# FUNÇÕES GERAIS
#####################
err_handler() {
  echo "❌ Erro no script: linha $1 – comando ‘${BASH_COMMAND}’" >&2
  exit 1
}
trap 'err_handler $LINENO' ERR

run_apt() {
  for i in $(seq 1 $RETRY_COUNT); do
    apt-get "$@" && return
    echo "⚠️ apt-get $* falhou (tentativa $i/$RETRY_COUNT)…" >&2
    sleep $RETRY_DELAY
  done
  echo "❌ apt-get $* falhou após $RETRY_COUNT tentativas." >&2
  exit 1
}

run_curl() {
  curl --retry $RETRY_COUNT --retry-delay $RETRY_DELAY --connect-timeout 10 "$@"
}

check_cmd() {
  command -v "$1" >/dev/null || { echo "❌ Comando \"$1\" não encontrado. Abortando." >&2; exit 1; }
}

#####################
# 1. CHECAGENS INICIAIS
#####################
[[ $EUID -eq 0 ]] || { echo "❌ Rode como root (use sudo)." >&2; exit 1; }
echo "🔐 Iniciando configuração para: $SERVER_USER"

# comandos obrigatórios
for cmd in curl gpg lsb_release; do
  check_cmd "$cmd"
done

# testando rede
ping -c1 8.8.8.8 >/dev/null || { echo "❌ Sem conectividade de rede."; exit 1; }
run_curl -fsSL https://download.docker.com >/dev/null || echo "⚠️ Repositório Docker inacessível."

#####################
# 2. PREPARAÇÃO PARA APT
#####################
echo "⌛ Aguardando locks do apt e parando timers automáticos..."
systemctl stop apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer || true
systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service || true
while pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x unattended-upgrade >/dev/null; do
  sleep 1
done

#####################
# 3. ATUALIZA SISTEMA E TIMEZONE
#####################
echo "📦 Atualizando sistema e timezone..."
export DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1
run_apt update -y
run_apt full-upgrade -y
run_apt autoremove -y
apt-get clean
ln -snf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

#####################
# 4. SWAP (4 GiB)
#####################
echo "💾 Configurando swap (4 GiB)…"
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/60-swap.conf
fi

#####################
# 5. OPENSSH + CHAVE
#####################
echo "🔑 Instalando OpenSSH e configurando chave..."
run_apt install -y openssh-server
systemctl enable --now ssh
if [ -n "$SSH_PUB_KEY" ]; then
  install -o "$SERVER_USER" -g "$SERVER_USER" -m 700 -d "/home/$SERVER_USER/.ssh"
  touch "/home/$SERVER_USER/.ssh/authorized_keys"
  grep -qxF "$SSH_PUB_KEY" "/home/$SERVER_USER/.ssh/authorized_keys" || \
    echo "$SSH_PUB_KEY" >> "/home/$SERVER_USER/.ssh/authorized_keys"
  chmod 600 "/home/$SERVER_USER/.ssh/authorized_keys"
fi

#####################
# 6. HARDENING SSH
#####################
echo "🛡️ Ajustando configuração SSH..."
cp /etc/ssh/sshd_config{,.bak.$(date +%F)}
sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -ri 's/^#?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
grep -q '^MaxAuthTries' /etc/ssh/sshd_config || echo 'MaxAuthTries 3' >> /etc/ssh/sshd_config
grep -q '^MaxStartups' /etc/ssh/sshd_config || echo 'MaxStartups 10:30:60' >> /etc/ssh/sshd_config
systemctl restart ssh

#####################
# 7. FIREWALL (UFW)
#####################
echo "🔥 Instalando/Configurando UFW..."
run_apt install -y ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment "SSH"
ufw allow 80,443/tcp comment "HTTP/S"
ufw --force enable
ufw status | grep -q "Status: active" || echo "⚠️ UFW não está ativo."

#####################
# 8. FAIL2BAN
#####################
echo "🚨 Instalando/Configurando Fail2Ban..."
run_apt install -y fail2ban
install -m 644 /dev/stdin /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime  = 1h
EOF
systemctl enable --now fail2ban
systemctl is-active --quiet fail2ban || echo "⚠️ Fail2Ban não iniciou."

#####################
# 9. DOCKER + COMPOSE
#####################
echo "🐳 Instalando Docker Engine e Compose v2..."
install -d -m 0755 /etc/apt/keyrings
run_curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
install -m 644 /dev/stdin /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable
EOF
run_apt update -y
run_apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "$SERVER_USER"
systemctl enable --now docker
systemctl is-active --quiet docker || { echo "❌ Docker não iniciou."; exit 1; }

#####################
# 10. HARDENING DOCKER
#####################
echo "🔒 Ajustando daemon Docker..."
install -d -m 0755 /etc/docker
install -m 644 /dev/stdin /etc/docker/daemon.json <<'EOF'
{
  "iptables": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" }
}
EOF
systemctl restart docker

#####################
# 11. WATCHTOWER
#####################
echo "📡 Instalando Watchtower..."
if ! docker ps --format '{{.Names}}' | grep -q watchtower; then
  docker run -d --name watchtower --restart always \
    -e WATCHTOWER_CLEANUP=true -e WATCHTOWER_POLL_INTERVAL=21600 \
    -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower
fi
docker ps | grep -q watchtower || echo "⚠️ Watchtower não está rodando."

#####################
# 12. SYSCTL & KERNEL TWEAKS
#####################
echo "⚙️ Aplicando sysctl custom…"
install -d -m 0755 /etc/sysctl.d
install -m 644 /dev/stdin /etc/sysctl.d/99-custom.conf <<'EOF'
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