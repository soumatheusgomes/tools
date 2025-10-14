#!/usr/bin/env bash
# ======================================================================
# 🔄 Ubuntu 24.04 – Script de MANUTENÇÃO/ATUALIZAÇÃO periódica
# - Pode rodar via cron/systemd timer com segurança (idempotente)
# - Atualiza pacotes (APT/Snap), Docker, stacks Docker Compose opcionais
# - Limpeza opcional (journal, imagens/volumes antigos), checa reboot
# - Log detalhado e lock para evitar execução concorrente
# ======================================================================

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------
# 🧩 PERSONALIZAÇÃO — edite conforme sua necessidade
# ----------------------------------------------------------------------

# APT
APT_FULL_UPGRADE=true             # full-upgrade com autoremove
APT_CLEAN_CACHE=true              # limpa cache do apt após upgrade
APT_STOP_TIMERS=true              # pausa apt-daily* para evitar locks

# SNAP
SNAP_REFRESH=true                 # atualiza pacotes snap (se snapd instalado)

# DOCKER
DOCKER_ENABLE=true                # executa tarefas Docker se binário existir
DOCKER_PRUNE_LEVEL="dangling"     # none | dangling | safe | aggressive
DOCKER_PRUNE_SAFE_UNTIL="168h"    # usado no modo "safe": não usados há >= 168h (7 dias)
DOCKER_RESTART_IF_INACTIVE=true   # garante docker ativo após upgrades
WATCHTOWER_REFRESH=true           # puxa/garante watchtower (se existir)
# Atualização de stacks Docker Compose (passe diretórios com docker-compose.yml / compose.yaml)
COMPOSE_STACKS=(                  # ex.: "/opt/stacks/prod" "/srv/blog"
)

# SISTEMA
APPLY_SYSCTL=true                 # reaplica sysctl --system (sincroniza ajustes)
RELOAD_SSHD=true                  # valida e recarrega sshd (sem desconectar sessões ativas)
RELOAD_FAIL2BAN=true              # reload no fail2ban se instalado
RELOAD_UFW=false                  # ufw reload (mantém regras), desative se usa regras muito dinâmicas

# LIMPEZAS
JOURNALCTL_VACUUM_TIME="14d"      # "" para desativar. Ex.: "7d" | "2G" | "1month"
VACUUM_TMP=true                   # limpa /tmp e /var/tmp (apenas arquivos > 7 dias)
PRUNE_OLD_SNAPS=true              # remove revisões antigas de snaps

# REBOOT
REBOOT_MODE="if_required"         # never | if_required | always
ANNOUNCE_REBOOT_SECONDS=60        # se reboot, anuncia via wall com antecedência

# OBSERVABILIDADE (opcional)
HEALTHCHECKS_START_URL=""         # URL para ping de start (healthchecks.io)
HEALTHCHECKS_SUCCESS_URL=""       # URL para ping de sucesso
HEALTHCHECKS_FAIL_URL=""          # URL para ping de falha

# LOG/LOCK
LOG_FILE="/var/log/maintenance_update.log"
LOCK_FILE="/var/run/maintenance_update.lock"
RETRY_COUNT=3
RETRY_DELAY=5

# ----------------------------------------------------------------------
# 🔧 Funções auxiliares
# ----------------------------------------------------------------------
log() { printf "%s %s\n" "[$(date +'%F %T')]" "$*" | tee -a "$LOG_FILE"; }
have() { command -v "$1" >/dev/null 2>&1; }
err_handler() {
  log "❌ Erro na linha $1: comando '${BASH_COMMAND}'"
  [[ -n "$HEALTHCHECKS_FAIL_URL" ]] && curl -fsS "$HEALTHCHECKS_FAIL_URL" >/dev/null 2>&1 || true
  rm -f "$LOCK_FILE" || true
  exit 1
}
trap 'err_handler $LINENO' ERR

is_true() { case "${1,,}" in true|1|yes|on) return 0 ;; *) return 1 ;; esac; }

run_apt() {
  for i in $(seq 1 "$RETRY_COUNT"); do
    if DEBIAN_FRONTEND=noninteractive apt-get -y "$@"; then return 0; fi
    log "⚠️ apt-get $* falhou (tentativa $i/$RETRY_COUNT), aguardando…"
    sleep "$RETRY_DELAY"
  done
  log "❌ apt-get $* falhou após $RETRY_COUNT tentativas."; return 1
}

curl_ping() { [[ -n "$1" ]] && curl -fsS "$1" >/dev/null 2>&1 || true; }

bytes_to_human() {
  local b=$1; local d='' s=0 S=(B KB MB GB TB PB EB ZB YB)
  while ((b>1024 && s<${#S[@]}-1)); do d="$(printf ".%02d" $(( (b%1024*100)/1024 )))"; b=$((b/1024)); s=$((s+1)); done
  printf "%s%s %s" "$b" "$d" "${S[$s]}"
}

disk_free_root() {
  df -B1 / | awk 'NR==2{print $4}'
}

pause_apt_timers() {
  systemctl stop apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer || true
  systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service || true
  while pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x unattended-upgrade >/dev/null; do sleep 1; done
}

# ----------------------------------------------------------------------
# 0) Pré-checagens / lock / logs
# ----------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "❌ Rode como root (sudo)."; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"
if [[ -e "$LOCK_FILE" ]]; then
  log "⚠️ Já existe lock: $LOCK_FILE — abortando para evitar concorrência."
  exit 0
fi
echo $$ > "$LOCK_FILE"

curl_ping "$HEALTHCHECKS_START_URL"
log "🔁 Iniciando manutenção periódica…"
log "📦 Free root antes: $(bytes_to_human "$(disk_free_root)")"

# ----------------------------------------------------------------------
# 1) APT: atualizar sistema
# ----------------------------------------------------------------------
if is_true "$APT_STOP_TIMERS"; then
  log "⏱️ Pausando timers apt para evitar locks…"
  pause_apt_timers
fi

log "🗂️ Atualizando índices APT…"
run_apt update

if is_true "$APT_FULL_UPGRADE"; then
  log "⬆️ Executando full-upgrade…"
  run_apt full-upgrade
  is_true "$APT_CLEAN_CACHE" && { run_apt autoremove; apt-get clean || true; }
else
  log "⬆️ Executando upgrade simples…"
  run_apt upgrade
fi

# ----------------------------------------------------------------------
# 2) Snap refresh (opcional)
# ----------------------------------------------------------------------
if is_true "$SNAP_REFRESH" && have snap; then
  log "📦 Atualizando snaps…"
  snap refresh || log "⚠️ snap refresh retornou código de erro (prosseguindo)."
  if is_true "$PRUNE_OLD_SNAPS"; then
    log "🧹 Removendo revisões antigas de snaps…"
    set +e
    snap list --all | awk '/disabled/{print $1, $3}' | while read -r name rev; do snap remove "$name" --revision="$rev"; done
    set -e
  fi
fi

# ----------------------------------------------------------------------
# 3) Docker: engine, prune, stacks compose
# ----------------------------------------------------------------------
if is_true "$DOCKER_ENABLE" && have docker; then
  log "🐳 Verificando Docker engine…"
  systemctl is-active --quiet docker || {
    is_true "$DOCKER_RESTART_IF_INACTIVE" && { log "🔁 Reiniciando Docker…"; systemctl restart docker || true; }
  }

  # Docker prune conforme política
  case "$DOCKER_PRUNE_LEVEL" in
    none)
      log "🧹 Docker prune: desativado."
      ;;
    dangling)
      log "🧹 Docker prune (dangling)…"
      docker system prune -f || true
      ;;
    safe)
      log "🧹 Docker prune SAFE (não usados há >= ${DOCKER_PRUNE_SAFE_UNTIL})…"
      docker image prune -af --filter "until=${DOCKER_PRUNE_SAFE_UNTIL}" || true
      docker container prune -f --filter "until=${DOCKER_PRUNE_SAFE_UNTIL}" || true
      ;;
    aggressive)
      log "🧹 Docker prune AGGRESSIVE (inclui volumes!)…"
      docker system prune -af --volumes || true
      ;;
    *)
      log "⚠️ Nível de prune desconhecido: $DOCKER_PRUNE_LEVEL"
      ;;
  esac

  # Watchtower opcional (pull + restart)
  if is_true "$WATCHTOWER_REFRESH"; then
    if docker ps --format '{{.Names}}' | grep -qx watchtower; then
      log "📡 Atualizando imagem do Watchtower…"
      docker pull containrrr/watchtower:latest || true
      docker restart watchtower || true
    fi
  fi

  # Atualizar stacks docker compose
  if ((${#COMPOSE_STACKS[@]})); then
    if docker compose version >/dev/null 2>&1; then
      for stack_dir in "${COMPOSE_STACKS[@]}"; do
        [[ -d "$stack_dir" ]] || { log "⚠️ Stack não encontrado: $stack_dir"; continue; }
        compose_file=""
        for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
          [[ -f "$stack_dir/$f" ]] && { compose_file="$stack_dir/$f"; break; }
        done
        if [[ -z "$compose_file" ]]; then
          log "⚠️ Nenhum compose*.yml encontrado em $stack_dir"
          continue
        fi
        log "📦 Atualizando stack: $stack_dir"
        ( cd "$stack_dir"
          docker compose pull
          docker compose up -d --remove-orphans
        ) || log "⚠️ Falha ao atualizar stack em $stack_dir (prosseguindo)."
      done
    else
      log "⚠️ 'docker compose' não disponível; pulando atualização de stacks."
    fi
  fi
else
  log "ℹ️ Docker desabilitado por config ou não instalado."
fi

# ----------------------------------------------------------------------
# 4) Serviços e segurança
# ----------------------------------------------------------------------
if is_true "$RELOAD_SSHD" && have sshd && systemctl is-enabled --quiet ssh; then
  log "🔐 Validando configuração do sshd…"
  if sshd -t 2>>"$LOG_FILE"; then
    systemctl reload ssh || true
  else
    log "⚠️ sshd -t encontrou problemas; NÃO recarregado (ver log)."
  fi
fi

if is_true "$RELOAD_FAIL2BAN" && have fail2ban-client && systemctl is-enabled --quiet fail2ban; then
  log "🚨 Recarregando Fail2Ban…"
  fail2ban-client reload || log "⚠️ fail2ban reload retornou erro (prosseguindo)."
fi

if is_true "$RELOAD_UFW" && have ufw; then
  log "🔥 Recarregando UFW…"
  ufw reload || log "⚠️ ufw reload retornou erro (prosseguindo)."
fi

if is_true "$APPLY_SYSCTL"; then
  log "⚙️ Aplicando sysctl --system…"
  sysctl --system >/dev/null || log "⚠️ sysctl --system retornou erro (prosseguindo)."
fi

# ----------------------------------------------------------------------
# 5) Limpezas diversas
# ----------------------------------------------------------------------
if [[ -n "$JOURNALCTL_VACUUM_TIME" ]] && have journalctl; then
  log "🧽 Compactando logs do journal (vacuum: $JOURNALCTL_VACUUM_TIME)…"
  journalctl --vacuum-time="$JOURNALCTL_VACUUM_TIME" || true
fi

if is_true "$VACUUM_TMP"; then
  log "🧹 Limpando arquivos antigos em /tmp e /var/tmp (>7d)…"
  find /tmp -xdev -type f -mtime +7 -print0 2>/dev/null | xargs -0r rm -f || true
  find /var/tmp -xdev -type f -mtime +7 -print0 2>/dev/null | xargs -0r rm -f || true
fi

# ----------------------------------------------------------------------
# 6) Reboot (conforme política)
# ----------------------------------------------------------------------
need_reboot=false
[[ -f /var/run/reboot-required ]] && need_reboot=true

case "$REBOOT_MODE" in
  always)
    log "🔁 REBOOT: agendado (modo = always)."
    wall "⚠️ Servidor será reiniciado em ${ANNOUNCE_REBOOT_SECONDS}s para concluir manutenção." || true
    sleep "$ANNOUNCE_REBOOT_SECONDS"
    curl_ping "$HEALTHCHECKS_SUCCESS_URL"
    rm -f "$LOCK_FILE" || true
    reboot
    ;;
  if_required)
    if $need_reboot; then
      log "🔁 REBOOT: necessário (kernel/libc atualizados)."
      wall "⚠️ Servidor será reiniciado em ${ANNOUNCE_REBOOT_SECONDS}s (atualizações críticas aplicadas)." || true
      sleep "$ANNOUNCE_REBOOT_SECONDS"
      curl_ping "$HEALTHCHECKS_SUCCESS_URL"
      rm -f "$LOCK_FILE" || true
      reboot
    else
      log "✅ REBOOT: não necessário."
    fi
    ;;
  never)
    log "🚫 REBOOT: desativado por configuração (há necessidade? $need_reboot)."
    ;;
  *)
    log "⚠️ REBOOT_MODE inválido: $REBOOT_MODE (usando if_required)."
    if $need_reboot; then
      wall "⚠️ Servidor será reiniciado em ${ANNOUNCE_REBOOT_SECONDS}s (atualizações críticas aplicadas)." || true
      sleep "$ANNOUNCE_REBOOT_SECONDS"
      curl_ping "$HEALTHCHECKS_SUCCESS_URL"
      rm -f "$LOCK_FILE" || true
      reboot
    fi
    ;;
esac

# ----------------------------------------------------------------------
# Fim
# ----------------------------------------------------------------------
log "📦 Free root depois: $(bytes_to_human "$(disk_free_root)")"
log "✅ Manutenção concluída sem reboot."
curl_ping "$HEALTHCHECKS_SUCCESS_URL"
rm -f "$LOCK_FILE" || true

# ======================================================================
# Sugestão de agendamento com systemd timer (salvar como /usr/local/sbin/maintenance.sh)
# chmod +x /usr/local/sbin/maintenance.sh
# cat >/etc/systemd/system/maintenance.service <<'UNIT'
# [Unit]
# Description=Maintenance & Update
# After=network-online.target
#
# [Service]
# Type=oneshot
# ExecStart=/usr/local/sbin/maintenance.sh
# Nice=10
# IOSchedulingClass=best-effort
# IOSchedulingPriority=4
#
# [Install]
# WantedBy=multi-user.target
# UNIT
#
# cat >/etc/systemd/system/maintenance.timer <<'UNIT'
# [Unit]
# Description=Run maintenance weekly
#
# [Timer]
# OnCalendar=Sun *-*-* 03:30:00
# Persistent=true
#
# [Install]
# WantedBy=timers.target
# UNIT
#
# systemctl daemon-reload
# systemctl enable --now maintenance.timer
# ======================================================================
