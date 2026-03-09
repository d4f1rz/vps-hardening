#!/bin/bash
# VPS Hardening Script
# Version: 1.3.2
# Compatibility: Ubuntu 20.04+ / Debian 11+

set -euo pipefail

VERSION="1.3.2"
LOG_FILE="/var/log/vps_hardening.log"
DRY_RUN=0
ROLLBACK=0

BACKUP_ROOT="/var/backups/vps_hardening"
BACKUP_ID=""
BACKUP_DIR=""
STATE_FILE="${BACKUP_ROOT}/last_state.env"
AUTOMATION_CONFIG_FILE="/etc/vps-hardening.conf"
INSTALLED_SCRIPT_PATH="/usr/local/sbin/vps_hardening.sh"
MAINT_SCRIPT_PATH="/usr/local/sbin/vps_hardening_maint.sh"
MAINT_LOG_FILE="/var/log/vps_hardening_maintenance.log"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/vps-hardening-maintenance.service"
SYSTEMD_TIMER_FILE="/etc/systemd/system/vps-hardening-maintenance.timer"
DEFAULT_SELF_UPDATE_URL="https://raw.githubusercontent.com/d4f1rz/vps-hardening/master/vps_hardening.sh"
DEFERRED_DELETE_DIR="/var/lib/vps-hardening"
DEFERRED_DELETE_LIST="${DEFERRED_DELETE_DIR}/deferred_delete_users.list"
DEFERRED_DELETE_SCRIPT="/usr/local/sbin/vps_hardening_deferred_delete.sh"
DEFERRED_DELETE_SERVICE="/etc/systemd/system/vps-hardening-deferred-delete.service"
DEFERRED_DELETE_TIMER="/etc/systemd/system/vps-hardening-deferred-delete.timer"
INTERACTIVE_FD=0

NEW_USER=""
NEW_USER_PASSWORD=""
SSH_PORT="2222"
SSH_SERVICE="sshd"
SERVER_IP=""
CLIENT_IP=""

ACCESS_MODE="all"     # all | selected
ALLOWED_IPS_CSV=""

MARZBAN_SERVICE_PORT="62050"
XRAY_API_PORT="62051"

# Firewall rule таблица для режима selected.
declare -a FW_RULE_NAMES=()
declare -a FW_RULE_SOURCES=()  # any | __SSH_CLIENT_IP__ | <IP/CIDR>
declare -a FW_RULE_PORTS=()    # __SSH__ | <port>
declare -a FW_RULE_NOTES=()

SSH_PRIVATE_KEY_CONTENT=""
SSH_PUBLIC_KEY_CONTENT=""
SSH_KEY_PASSPHRASE=""

DELETED_USERS_LIST_FILE=""

C_RESET="\033[0m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_BOLD="\033[1m"

print_info() { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
print_ok() { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
print_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
print_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  local msg="$*"
  echo "[$(timestamp)] ${msg}" >> "$LOG_FILE"
}

init_log() {
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  log "========== START vps_hardening.sh v${VERSION} =========="
}

show_help() {
  cat <<'EOF'
Использование:
  bash vps_hardening.sh [--dry-run] [--rollback] [--help]

Опции:
  --dry-run   Симуляция без реальных изменений.
  --rollback  Откат последнего применения hardening.
  --help      Показать справку.

Что делает скрипт:
  1) Обновляет систему
  2) Создает нового sudo-пользователя
  3) Удаляет старых пользователей (кроме root и нового)
  4) Генерирует SSH-ключи автоматически
  5) Усиливает SSH-конфиг
  6) Настраивает UFW (доступ: всем или только выбранным IP)
  7) Настраивает Fail2ban
  8) Перезапускает SSH
  9) Настраивает автозапуск и автообслуживание (self-update + update/upgrade)
  10) Показывает итоговый отчет
  11) Поддерживает rollback из snapshot-бэкапа
EOF
}

ask_confirm() {
  local prompt="$1"
  local answer

  if ! read_from_tty answer "$prompt [Y/n]: "; then
    print_error "Не удалось получить интерактивный ввод (TTY недоступен)."
    return 1
  fi

  answer="${answer:-Y}"
  case "$answer" in
    Y|y|yes|YES) return 0 ;;
    N|n|no|NO) return 1 ;;
    *) return 0 ;;
  esac
}

read_from_tty() {
  local __var_name="$1"
  local __prompt="$2"
  local __value=""

  read -r -u "$INTERACTIVE_FD" -p "$__prompt" __value || return 1

  printf -v "$__var_name" '%s' "$__value"
  return 0
}

init_interactive_io() {
  if [[ -t 0 ]]; then
    INTERACTIVE_FD=0
    return 0
  fi

  if [[ -r /dev/tty ]]; then
    exec 3<> /dev/tty
    INTERACTIVE_FD=3
    return 0
  fi

  print_error "Интерактивный режим недоступен: нет TTY. Запустите скрипт из интерактивной консоли."
  exit 1
}

handle_error() {
  local message="$1"
  print_error "$message"
  log "ERROR: $message"
  if ask_confirm "Продолжить несмотря на ошибку?"; then
    log "User chose to continue after error"
    return 0
  fi
  log "User chose to exit after error"
  exit 1
}

show_banner() {
  cat <<'EOF'
╔══════════════════════════════════════════════════════════╗
║            VPS HARDENING SCRIPT v1.3.2                  ║
║     Автоматическая защита VPS (Ubuntu/Debian)           ║
╚══════════════════════════════════════════════════════════╝
EOF
}

save_runtime_state() {
  if [[ "$DRY_RUN" -eq 1 || -z "$BACKUP_DIR" ]]; then
    return 0
  fi

  mkdir -p "$BACKUP_ROOT"
  cat > "$STATE_FILE" <<EOF
BACKUP_DIR="$BACKUP_DIR"
NEW_USER="$NEW_USER"
SSH_PORT="$SSH_PORT"
SSH_SERVICE="$SSH_SERVICE"
ACCESS_MODE="$ACCESS_MODE"
ALLOWED_IPS_CSV="$ALLOWED_IPS_CSV"
EOF
  chmod 600 "$STATE_FILE"
  log "State saved: $STATE_FILE"
}

init_backup_snapshot() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "[DRY-RUN] Snapshot-бэкап не создается"
    return 0
  fi

  BACKUP_ID="$(date +%Y%m%d_%H%M%S)"
  BACKUP_DIR="${BACKUP_ROOT}/${BACKUP_ID}"
  DELETED_USERS_LIST_FILE="${BACKUP_DIR}/deleted_users/list.txt"

  mkdir -p "$BACKUP_DIR/files"
  mkdir -p "${BACKUP_DIR}/deleted_users"

  if [[ -f /etc/ssh/sshd_config ]]; then
    cp /etc/ssh/sshd_config "${BACKUP_DIR}/files/sshd_config.before"
  fi

  if [[ -f /etc/fail2ban/jail.local ]]; then
    cp /etc/fail2ban/jail.local "${BACKUP_DIR}/files/jail.local.before"
  fi

  if [[ -f /etc/ufw/user.rules ]]; then
    cp /etc/ufw/user.rules "${BACKUP_DIR}/files/ufw_user.rules.before"
  fi

  if [[ -f /etc/ufw/user6.rules ]]; then
    cp /etc/ufw/user6.rules "${BACKUP_DIR}/files/ufw_user6.rules.before"
  fi

  if [[ -f "$AUTOMATION_CONFIG_FILE" ]]; then
    cp "$AUTOMATION_CONFIG_FILE" "${BACKUP_DIR}/files/vps-hardening.conf.before"
  fi

  if [[ -f "$INSTALLED_SCRIPT_PATH" ]]; then
    cp "$INSTALLED_SCRIPT_PATH" "${BACKUP_DIR}/files/vps_hardening.sh.before"
  fi

  if [[ -f "$MAINT_SCRIPT_PATH" ]]; then
    cp "$MAINT_SCRIPT_PATH" "${BACKUP_DIR}/files/vps_hardening_maint.sh.before"
  fi

  if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
    cp "$SYSTEMD_SERVICE_FILE" "${BACKUP_DIR}/files/vps-hardening-maintenance.service.before"
  fi

  if [[ -f "$SYSTEMD_TIMER_FILE" ]]; then
    cp "$SYSTEMD_TIMER_FILE" "${BACKUP_DIR}/files/vps-hardening-maintenance.timer.before"
  fi

  ufw status verbose > "${BACKUP_DIR}/files/ufw_status.before" 2>/dev/null || true

  save_runtime_state
  print_ok "Snapshot для отката создан: ${BACKUP_DIR}"
  log "Backup snapshot created: $BACKUP_DIR"
}

backup_deleted_user() {
  local user="$1"

  if [[ "$DRY_RUN" -eq 1 || -z "$BACKUP_DIR" ]]; then
    return 0
  fi

  local udir="${BACKUP_DIR}/deleted_users/${user}"
  mkdir -p "$udir"

  getent passwd "$user" > "${udir}/passwd" || true
  getent shadow "$user" > "${udir}/shadow" || true
  id -nG "$user" > "${udir}/groups" 2>/dev/null || true

  local home_dir
  home_dir="$(getent passwd "$user" | awk -F: '{print $6}')"
  if [[ -n "$home_dir" && -d "$home_dir" ]]; then
    tar -czf "${udir}/home.tar.gz" -C / "${home_dir#/}" >/dev/null 2>&1 || true
  fi

  echo "$user" >> "$DELETED_USERS_LIST_FILE"
  log "Prepared rollback backup for deleted user: $user"
}

rollback_last() {
  print_step_header "R" "Откат конфигурации" "Восстанавливаем последнее состояние сервера из snapshot-бэкапа."

  if [[ ! -f "$STATE_FILE" ]]; then
    print_error "Файл состояния не найден: $STATE_FILE"
    print_error "Откат невозможен: не найден snapshot предыдущего запуска."
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$STATE_FILE"

  if [[ -z "${BACKUP_DIR:-}" || ! -d "${BACKUP_DIR}" ]]; then
    print_error "Каталог snapshot не найден: ${BACKUP_DIR:-<empty>}"
    exit 1
  fi

  print_info "Откат из: $BACKUP_DIR"
  log "ROLLBACK start from: $BACKUP_DIR"

  if [[ -f "${BACKUP_DIR}/files/sshd_config.before" ]]; then
    run_cmd "cp \"${BACKUP_DIR}/files/sshd_config.before\" /etc/ssh/sshd_config" "Восстановление sshd_config"
  fi

  if [[ -f "${BACKUP_DIR}/files/jail.local.before" ]]; then
    run_cmd "cp \"${BACKUP_DIR}/files/jail.local.before\" /etc/fail2ban/jail.local" "Восстановление jail.local"
  else
    if [[ -f /etc/fail2ban/jail.local ]]; then
      run_cmd "rm -f /etc/fail2ban/jail.local" "Удаление созданного jail.local"
    fi
  fi

  if [[ -f "${BACKUP_DIR}/files/ufw_user.rules.before" ]]; then
    run_cmd "cp \"${BACKUP_DIR}/files/ufw_user.rules.before\" /etc/ufw/user.rules" "Восстановление UFW IPv4 правил"
  fi

  if [[ -f "${BACKUP_DIR}/files/ufw_user6.rules.before" ]]; then
    run_cmd "cp \"${BACKUP_DIR}/files/ufw_user6.rules.before\" /etc/ufw/user6.rules" "Восстановление UFW IPv6 правил"
  fi

  if [[ -f "${BACKUP_DIR}/files/vps-hardening.conf.before" ]]; then
    run_cmd "cp \"${BACKUP_DIR}/files/vps-hardening.conf.before\" \"${AUTOMATION_CONFIG_FILE}\"" "Восстановление automation-конфига"
  else
    if [[ -f "$AUTOMATION_CONFIG_FILE" ]]; then
      run_cmd "rm -f \"${AUTOMATION_CONFIG_FILE}\"" "Удаление automation-конфига"
    fi
  fi

  if [[ -f "${BACKUP_DIR}/files/vps_hardening.sh.before" ]]; then
    run_cmd "cp \"${BACKUP_DIR}/files/vps_hardening.sh.before\" \"${INSTALLED_SCRIPT_PATH}\"" "Восстановление установленного скрипта"
    run_cmd "chmod 700 \"${INSTALLED_SCRIPT_PATH}\"" "Права на установленный скрипт"
  else
    if [[ -f "$INSTALLED_SCRIPT_PATH" ]]; then
      run_cmd "rm -f \"${INSTALLED_SCRIPT_PATH}\"" "Удаление установленного скрипта"
    fi
  fi

  if [[ -f "${BACKUP_DIR}/files/vps_hardening_maint.sh.before" ]]; then
    run_cmd "cp \"${BACKUP_DIR}/files/vps_hardening_maint.sh.before\" \"${MAINT_SCRIPT_PATH}\"" "Восстановление maintenance-скрипта"
    run_cmd "chmod 700 \"${MAINT_SCRIPT_PATH}\"" "Права на maintenance-скрипт"
  else
    if [[ -f "$MAINT_SCRIPT_PATH" ]]; then
      run_cmd "rm -f \"${MAINT_SCRIPT_PATH}\"" "Удаление maintenance-скрипта"
    fi
  fi

  if [[ -f "${BACKUP_DIR}/files/vps-hardening-maintenance.service.before" ]]; then
    run_cmd "cp \"${BACKUP_DIR}/files/vps-hardening-maintenance.service.before\" \"${SYSTEMD_SERVICE_FILE}\"" "Восстановление systemd service"
  else
    if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
      run_cmd "rm -f \"${SYSTEMD_SERVICE_FILE}\"" "Удаление systemd service"
    fi
  fi

  if [[ -f "${BACKUP_DIR}/files/vps-hardening-maintenance.timer.before" ]]; then
    run_cmd "cp \"${BACKUP_DIR}/files/vps-hardening-maintenance.timer.before\" \"${SYSTEMD_TIMER_FILE}\"" "Восстановление systemd timer"
  else
    run_cmd "systemctl disable --now vps-hardening-maintenance.timer || true" "Отключение timer auto-maintenance"
    if [[ -f "$SYSTEMD_TIMER_FILE" ]]; then
      run_cmd "rm -f \"${SYSTEMD_TIMER_FILE}\"" "Удаление systemd timer"
    fi
  fi

  run_cmd "systemctl daemon-reload" "Перезагрузка systemd unit-файлов после отката"

  run_cmd "ufw --force reload" "Перезагрузка UFW"

  local restore_user
  local list_file="${BACKUP_DIR}/deleted_users/list.txt"
  if [[ -f "$list_file" ]]; then
    while IFS= read -r restore_user; do
      [[ -z "$restore_user" ]] && continue

      local udir="${BACKUP_DIR}/deleted_users/${restore_user}"
      local passwd_line
      local shadow_line

      passwd_line="$(cat "${udir}/passwd" 2>/dev/null || true)"
      shadow_line="$(cat "${udir}/shadow" 2>/dev/null || true)"

      if [[ -z "$passwd_line" ]]; then
        continue
      fi

      if id "$restore_user" >/dev/null 2>&1; then
        print_warn "Пользователь ${restore_user} уже существует, пропускаем восстановление."
      else
        local x name uid gid gecos home shell
        IFS=':' read -r name x uid gid gecos home shell <<< "$passwd_line"

        if ! getent group "$gid" >/dev/null 2>&1; then
          run_cmd "groupadd -g ${gid} ${name}" "Восстановление primary group для ${name}"
        fi

        run_cmd "useradd -u ${uid} -g ${gid} -d \"${home}\" -s \"${shell}\" -c \"${gecos}\" -M ${name}" "Восстановление пользователя ${name}"

        if [[ -n "$shadow_line" ]]; then
          local hash
          hash="$(echo "$shadow_line" | awk -F: '{print $2}')"
          if [[ -n "$hash" ]]; then
            run_cmd "usermod -p '${hash}' ${name}" "Восстановление hash-пароля для ${name}"
          fi
        fi

        if [[ -f "${udir}/groups" ]]; then
          local g
          for g in $(cat "${udir}/groups"); do
            if [[ "$g" == "$name" ]]; then
              continue
            fi
            if getent group "$g" >/dev/null 2>&1; then
              run_cmd "usermod -aG ${g} ${name}" "Возврат группы ${g} для ${name}"
            fi
          done
        fi

        if [[ -f "${udir}/home.tar.gz" ]]; then
          run_cmd "tar -xzf \"${udir}/home.tar.gz\" -C /" "Восстановление home для ${name}"
          run_cmd "chown -R ${name}:${name} \"${home}\"" "Исправление владельца home для ${name}"
        fi
      fi
    done < "$list_file"
  fi

  if [[ -n "${NEW_USER:-}" && "$NEW_USER" != "root" ]]; then
    if id "$NEW_USER" >/dev/null 2>&1; then
      safe_delete_user "$NEW_USER" "Удаление пользователя hardening: ${NEW_USER}"
    fi
  fi

  if [[ -n "${SSH_SERVICE:-}" ]]; then
    run_cmd "systemctl restart ${SSH_SERVICE}" "Перезапуск SSH после отката"
  else
    run_cmd "systemctl restart sshd || systemctl restart ssh" "Перезапуск SSH после отката"
  fi

  run_cmd "systemctl restart fail2ban || true" "Перезапуск Fail2ban после отката"

  print_ok "Откат завершен. Проверьте доступ к серверу и статус сервисов."
  log "ROLLBACK finished"
}

set_sshd_defaults_for_reinstall() {
  set_sshd_option "Port" "22"
  set_sshd_option "PermitRootLogin" "yes"
  set_sshd_option "PasswordAuthentication" "yes"
  set_sshd_option "PubkeyAuthentication" "yes"
  set_sshd_option "AuthorizedKeysFile" ".ssh/authorized_keys .ssh/authorized_keys2"
  set_sshd_option "X11Forwarding" "yes"
  set_sshd_option "MaxAuthTries" "6"
  set_sshd_option "LoginGraceTime" "120"
}

purge_all_authorized_keys() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "[DRY-RUN] Пропущено удаление authorized_keys"
    return 0
  fi

  find /root /home -maxdepth 3 -type f -name authorized_keys -print -delete >> "$LOG_FILE" 2>&1 || true
  log "Authorized keys removed under /root and /home"
}

reset_to_legacy_baseline() {
  print_step_header "R0" "Сброс к базовой конфигурации" "Выполняем fallback-сброс для старых установок без snapshot."

  # Удаляем automation артефакты, если были.
  run_cmd "systemctl disable --now vps-hardening-maintenance.timer || true" "Отключение timer auto-maintenance"
  run_cmd "systemctl disable --now vps-hardening-deferred-delete.timer || true" "Отключение timer отложенного удаления"
  run_cmd "rm -f \"${SYSTEMD_TIMER_FILE}\" \"${SYSTEMD_SERVICE_FILE}\" \"${MAINT_SCRIPT_PATH}\" \"${AUTOMATION_CONFIG_FILE}\"" "Удаление automation-файлов"
  run_cmd "rm -f \"${DEFERRED_DELETE_TIMER}\" \"${DEFERRED_DELETE_SERVICE}\" \"${DEFERRED_DELETE_SCRIPT}\" \"${DEFERRED_DELETE_LIST}\"" "Удаление файлов отложенного удаления"
  run_cmd "systemctl daemon-reload" "Обновление systemd после удаления automation"

  # SSH к более дефолтному состоянию.
  if [[ -f /etc/ssh/sshd_config ]]; then
    set_sshd_defaults_for_reinstall
    run_cmd "rm -f /etc/ssh/sshd_config.bak" "Удаление старого sshd_config.bak маркера"
    local sshd_bin
    sshd_bin="$(command -v sshd || true)"
    if [[ -n "$sshd_bin" ]]; then
      run_cmd "\"${sshd_bin}\" -t" "Проверка sshd_config после сброса"
    fi
  fi

  # Чистим ключи доступа и восстанавливаем парольный root вход.
  purge_all_authorized_keys

  local new_root_password
  new_root_password="$(gen_secret 16)"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf 'root:%s\n' "$new_root_password" | chpasswd
    log "Root password reset during reinstall baseline"
    echo
    echo "╔══════════════════════════════════════════════╗"
    echo "║     НОВЫЙ ROOT ПАРОЛЬ (СОХРАНИТЕ ЕГО)       ║"
    echo "╠══════════════════════════════════════════════╣"
    printf "║ root: %-35s ║\n" "$new_root_password"
    echo "╚══════════════════════════════════════════════╝"
  else
    print_warn "[DRY-RUN] Пропущен сброс root-пароля"
  fi

  # Пользователи: удаляем все интерактивные, кроме root.
  local user uid shell
  while IFS=: read -r user _ uid _ _ _ shell; do
    if [[ "$uid" -lt 1000 ]]; then
      continue
    fi
    if [[ "$user" == "root" || "$user" == "nobody" ]]; then
      continue
    fi
    if [[ "$shell" == */nologin || "$shell" == */false ]]; then
      continue
    fi
    safe_delete_user "$user" "Удаление пользователя ${user} при переустановке"
  done < /etc/passwd

  # UFW и Fail2ban к базовому виду.
  run_cmd "ufw --force disable || true" "Отключение UFW"
  run_cmd "echo 'y' | ufw --force reset || true" "Сброс правил UFW"

  if [[ -f /etc/fail2ban/jail.local ]]; then
    run_cmd "rm -f /etc/fail2ban/jail.local" "Удаление jail.local"
  fi
  run_cmd "systemctl disable --now fail2ban || true" "Отключение Fail2ban"

  run_cmd "systemctl restart ${SSH_SERVICE} || systemctl restart sshd || systemctl restart ssh" "Перезапуск SSH после сброса"
}

is_hardening_already_present() {
  # Новый формат (состояние, automation).
  if [[ -f "$STATE_FILE" || -f "$AUTOMATION_CONFIG_FILE" || -f "$SYSTEMD_TIMER_FILE" ]]; then
    return 0
  fi

  # Наследие старых версий: jail.local, активный ufw, измененный SSH.
  if [[ -f /etc/fail2ban/jail.local ]]; then
    return 0
  fi

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      return 0
    fi
  fi

  if [[ -f /etc/ssh/sshd_config ]]; then
    if grep -Eq '^[[:space:]]*Port[[:space:]]+(2222|[1-9][0-9]{3,4})' /etc/ssh/sshd_config; then
      return 0
    fi
    if grep -Eq '^[[:space:]]*PermitRootLogin[[:space:]]+no' /etc/ssh/sshd_config; then
      return 0
    fi
    if grep -Eq '^[[:space:]]*PasswordAuthentication[[:space:]]+no' /etc/ssh/sshd_config; then
      return 0
    fi
  fi

  return 1
}

handle_reinstall_if_needed() {
  if ! is_hardening_already_present; then
    return 0
  fi

  echo
  print_warn "Похоже, hardening уже настроен на этом сервере."
  print_info "Можно выполнить переустановку: автоматический откат к базовому состоянию и повторная настройка с нуля."

  if ! ask_confirm "Выполнить переустановку сейчас?"; then
    print_warn "Переустановка отменена. Скрипт завершен без изменений."
    exit 0
  fi

  if [[ -f "$STATE_FILE" ]]; then
    print_info "Найден snapshot/state. Выполняется откат последнего запуска..."
    rollback_last
  else
    print_warn "Snapshot не найден (возможно старая версия скрипта). Запускается fallback-сброс."
    reset_to_legacy_baseline
  fi

  print_ok "Сброс завершен, начинается новая чистая настройка."
}

print_step_header() {
  local step_num="$1"
  local title="$2"
  local description="$3"
  echo
  echo -e "${C_BOLD}Шаг ${step_num}. ${title}${C_RESET}"
  echo -e "${C_YELLOW}${description}${C_RESET}"
  log "STEP ${step_num}: ${title}"
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --rollback)
        ROLLBACK=1
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        print_error "Неизвестный аргумент: $1"
        show_help
        exit 1
        ;;
    esac
    shift
  done
}

run_cmd() {
  local cmd="$1"
  local action="${2:-$1}"

  print_info "Команда: $cmd"
  log "CMD: $cmd"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "[DRY-RUN] Пропущено: $action"
    log "DRY-RUN: skipped -> $action"
    return 0
  fi

  local spin='|/-\\'
  local i=0

  set +e
  bash -c "$cmd" >> "$LOG_FILE" 2>&1 &
  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\r${C_BLUE}[RUN]${C_RESET} %s %c" "$action" "${spin:$i:1}"
    sleep 0.12
  done

  wait "$pid"
  local rc=$?
  set -e

  # Очищаем строку статуса перед следующим действием.
  printf "\r\033[2K"

  if [[ "$rc" -ne 0 ]]; then
    handle_error "Ошибка выполнения: $action (код $rc)"
    return 1
  fi

  print_ok "$action"
  return 0
}

validate_username() {
  local username="$1"
  [[ "$username" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ "$username" != "root" ]] || return 1
  return 0
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1024 && port <= 65535 )) || return 1
  return 0
}

validate_ip_or_cidr() {
  local value="$1"
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]
}

gen_secret() {
  local len="$1"
  local chars='A-Za-z0-9!@#%^*_+=-'
  local result=""

  # В режиме pipefail конвейер tr|head может завершаться SIGPIPE.
  # Поэтому временно выключаем pipefail и добираем длину в цикле.
  set +o pipefail
  while [[ "${#result}" -lt "$len" ]]; do
    result+="$(LC_ALL=C tr -dc "$chars" < /dev/urandom | head -c "$len")"
  done
  set -o pipefail

  echo "${result:0:$len}"
}

check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    print_error "Скрипт нужно запускать от root: sudo bash vps_hardening.sh"
    exit 1
  fi
}

check_os() {
  local id=""
  local id_like=""

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    id="${ID:-}"
    id_like="${ID_LIKE:-}"
  fi

  if [[ "$id" != "ubuntu" && "$id" != "debian" && "$id_like" != *"debian"* ]]; then
    print_warn "ОС не из списка поддержки: ID=${id:-unknown}, ID_LIKE=${id_like:-unknown}"
    if ! ask_confirm "Продолжить на этой ОС?"; then
      exit 1
    fi
  else
    print_ok "ОС совместима: ${id:-unknown}"
  fi

  log "OS: ID=${id:-unknown}, ID_LIKE=${id_like:-unknown}"
}

detect_ssh_service() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    SSH_SERVICE="sshd"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    SSH_SERVICE="ssh"
  else
    SSH_SERVICE="sshd"
  fi
  log "SSH service: $SSH_SERVICE"
}

detect_current_ssh_port() {
  local sshd_bin
  local detected
  sshd_bin="$(command -v sshd || true)"
  if [[ -z "$sshd_bin" ]]; then
    SSH_PORT="22"
    log "Current SSH port detection skipped: sshd not found, fallback 22"
    return 0
  fi

  detected="$("$sshd_bin" -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  if validate_port "$detected"; then
    SSH_PORT="$detected"
    log "Current SSH port detected: $SSH_PORT"
  else
    SSH_PORT="22"
    log "Current SSH port detection fallback to 22"
  fi
}

get_server_ip() {
  SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  SERVER_IP="${SERVER_IP:-<IP_СЕРВЕРА>}"
}

is_valid_remote_ip() {
  local ip="$1"
  [[ -n "$ip" ]] || return 1
  [[ "$ip" != "127.0.0.1" ]] || return 1
  [[ "$ip" != "::1" ]] || return 1
  [[ "$ip" != "localhost" ]] || return 1
  return 0
}

get_client_ip() {
  local candidate=""
  local tty_name="${SSH_TTY:-}"

  candidate="$(echo "${SSH_CONNECTION:-}" | awk '{print $1}')"
  if is_valid_remote_ip "$candidate"; then
    CLIENT_IP="$candidate"
    log "Client IP detected from SSH_CONNECTION: $CLIENT_IP"
    return 0
  fi

  candidate="$(echo "${SSH_CLIENT:-}" | awk '{print $1}')"
  if is_valid_remote_ip "$candidate"; then
    CLIENT_IP="$candidate"
    log "Client IP detected from SSH_CLIENT: $CLIENT_IP"
    return 0
  fi

  if [[ -n "$tty_name" ]]; then
    candidate="$(who 2>/dev/null | awk -v t="$tty_name" '$2==substr(t,6){print $5}' | tr -d '()' | head -n1)"
    if is_valid_remote_ip "$candidate"; then
      CLIENT_IP="$candidate"
      log "Client IP detected from who/SSH_TTY: $CLIENT_IP"
      return 0
    fi
  fi

  candidate="$(who am i 2>/dev/null | awk '{print $5}' | tr -d '()')"
  if is_valid_remote_ip "$candidate"; then
    CLIENT_IP="$candidate"
    log "Client IP detected from who am i: $CLIENT_IP"
    return 0
  fi

  if [[ -f /var/log/auth.log ]]; then
    candidate="$(grep -E 'sshd\[[0-9]+\]: Accepted .* from ' /var/log/auth.log | tail -n1 | sed -E 's/.* from ([^ ]+).*/\1/')"
    if is_valid_remote_ip "$candidate"; then
      CLIENT_IP="$candidate"
      log "Client IP detected from /var/log/auth.log: $CLIENT_IP"
      return 0
    fi
  fi

  if command -v journalctl >/dev/null 2>&1; then
    candidate="$(journalctl -u ssh -u sshd -n 200 --no-pager 2>/dev/null | grep -E 'Accepted .* from ' | tail -n1 | sed -E 's/.* from ([^ ]+).*/\1/')"
    if is_valid_remote_ip "$candidate"; then
      CLIENT_IP="$candidate"
      log "Client IP detected from journalctl: $CLIENT_IP"
      return 0
    fi
  fi

  print_warn "Не удалось автоматически определить внешний IP SSH-клиента."
  while true; do
    read_from_tty candidate "Введите ваш внешний IP вручную: " || break
    if validate_ip_or_cidr "$candidate"; then
      candidate="${candidate%%/*}"
      if is_valid_remote_ip "$candidate"; then
        CLIENT_IP="$candidate"
        log "Client IP set manually: $CLIENT_IP"
        return 0
      fi
    fi
    print_warn "Введите корректный внешний IP (не localhost)."
  done

  CLIENT_IP="127.0.0.1"
  log "Client IP detected: $CLIENT_IP"
}

fw_add_rule() {
  local name="$1"
  local src="$2"
  local port="$3"
  local note="$4"
  FW_RULE_NAMES+=("$name")
  FW_RULE_SOURCES+=("$src")
  FW_RULE_PORTS+=("$port")
  FW_RULE_NOTES+=("$note")
}

resolve_fw_source() {
  local src="$1"
  if [[ "$src" == "__SSH_CLIENT_IP__" ]]; then
    echo "$CLIENT_IP"
  else
    echo "$src"
  fi
}

resolve_fw_port() {
  local port="$1"
  if [[ "$port" == "__SSH__" ]]; then
    echo "$SSH_PORT"
  else
    echo "$port"
  fi
}

rebuild_allowed_ips_csv() {
  local i src resolved
  local unique=()
  ALLOWED_IPS_CSV=""

  for ((i=0; i<${#FW_RULE_SOURCES[@]}; i++)); do
    src="${FW_RULE_SOURCES[$i]}"
    resolved="$(resolve_fw_source "$src")"
    if [[ "$resolved" == "any" ]]; then
      continue
    fi
    if [[ ",${unique[*]}," != *",${resolved},"* ]]; then
      unique+=("$resolved")
    fi
  done

  if [[ "${#unique[@]}" -gt 0 ]]; then
    ALLOWED_IPS_CSV="$(IFS=,; echo "${unique[*]}")"
  fi
}

render_fw_table() {
  echo
  echo "╔══════════════════════════════════════════════════════════════════════════════════════════╗"
  echo "║ ACL/FW ПРАВИЛА (режим selected)                                                        ║"
  echo "╠════╦════════════════════╦══════════════════════╦════════════╦═══════════════════════════╣"
  echo "║ #  ║ Name               ║ Source               ║ Port       ║ Note                      ║"
  echo "╠════╬════════════════════╬══════════════════════╬════════════╬═══════════════════════════╣"
  local i src port
  if [[ "${#FW_RULE_NAMES[@]}" -eq 0 ]]; then
    echo "║ -- ║ (пока пусто)       ║ -                    ║ -          ║ -                         ║"
  else
    for ((i=0; i<${#FW_RULE_NAMES[@]}; i++)); do
      src="$(resolve_fw_source "${FW_RULE_SOURCES[$i]}")"
      port="$(resolve_fw_port "${FW_RULE_PORTS[$i]}")"
      printf "║ %-2s ║ %-18s ║ %-20s ║ %-10s ║ %-25s ║\n" "$((i+1))" "${FW_RULE_NAMES[$i]}" "$src" "$port" "${FW_RULE_NOTES[$i]}"
    done
  fi
  echo "╚════╩════════════════════╩══════════════════════╩════════════╩═══════════════════════════╝"
}

redraw_acl_screen() {
  if [[ -t 1 ]]; then
    printf '\033[2J\033[H'
  fi
  show_banner
  echo
  echo "Режим ACL (selected). Текущий SSH IP: ${CLIENT_IP}, текущий SSH порт: ${SSH_PORT}"
  render_fw_table
  echo "Добавить правило/шаблон:"
  echo "  1) Marzban-host"
  echo "  2) Marzban-node"
  echo "  3) Custom rule"
  echo "  4) Завершить"
}

add_profile_marzban_host() {
  fw_add_rule "marzban-host:ssh" "__SSH_CLIENT_IP__" "__SSH__" "SSH admin from current IP"
  fw_add_rule "marzban-host:web80" "any" "80" "HTTP for cert/website"
  fw_add_rule "marzban-host:web443" "any" "443" "HTTPS public"
}

add_profile_marzban_node() {
  local host_ip
  while true; do
    read_from_tty host_ip "Введите IP/CIDR Marzban-host: " || return 1
    if validate_ip_or_cidr "$host_ip"; then
      break
    fi
    print_warn "Некорректный IP/CIDR."
  done

  fw_add_rule "marzban-node:ssh" "__SSH_CLIENT_IP__" "__SSH__" "SSH admin from current IP"
  fw_add_rule "marzban-node:80" "any" "80" "HTTP для certbot (временно/по задаче)"
  fw_add_rule "marzban-node:443" "any" "443" "HTTPS ingress"
  fw_add_rule "marzban-node:62050" "$host_ip" "$MARZBAN_SERVICE_PORT" "Marzban Node service"
  fw_add_rule "marzban-node:62051" "$host_ip" "$XRAY_API_PORT" "Xray API for host"
}

add_custom_rule() {
  local name src_choice src port_choice port
  while true; do
    read_from_tty name "Имя custom-правила: " || return 1
    name="${name:-custom-$((${#FW_RULE_NAMES[@]}+1))}"
    if [[ "$name" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      break
    fi
    print_warn "Имя правила: только буквы/цифры/._:-"
  done

  echo "Источник доступа:"
  echo "  1) all"
  echo "  2) current-ssh-ip"
  echo "  3) specific IP/CIDR"
  while true; do
    read_from_tty src_choice "Ваш выбор [1/2/3]: " || return 1
    case "$src_choice" in
      1) src="any"; break ;;
      2) src="__SSH_CLIENT_IP__"; break ;;
      3)
        while true; do
          read_from_tty src "Введите IP/CIDR: " || return 1
          if validate_ip_or_cidr "$src"; then
            break
          fi
          print_warn "Некорректный IP/CIDR."
        done
        break
        ;;
      *) print_warn "Введите 1, 2 или 3." ;;
    esac
  done

  echo "Порт правила:"
  echo "  1) __SSH__ (автоподстановка текущего SSH-порта)"
  echo "  2) custom numeric"
  while true; do
    read_from_tty port_choice "Ваш выбор [1/2]: " || return 1
    case "$port_choice" in
      1) port="__SSH__"; break ;;
      2)
        while true; do
          read_from_tty port "Введите TCP порт: " || return 1
          if validate_port "$port"; then
            break
          fi
          print_warn "Некорректный порт."
        done
        break
        ;;
      *) print_warn "Введите 1 или 2." ;;
    esac
  done

  fw_add_rule "$name" "$src" "$port" "custom"
}

choose_access_mode() {
  echo
  echo "Выберите модель доступа по IP для SSH:"
  echo "  1) Разрешить вход с любых IP"
  echo "  2) Режим ACL (таблица правил и профили)"

  local choice
  while true; do
    read_from_tty choice "Ваш выбор [1/2]: " || return 1
    case "$choice" in
      1)
        ACCESS_MODE="all"
        ALLOWED_IPS_CSV=""
        break
        ;;
      2)
        ACCESS_MODE="selected"
        FW_RULE_NAMES=()
        FW_RULE_SOURCES=()
        FW_RULE_PORTS=()
        FW_RULE_NOTES=()

        get_client_ip
        print_info "Текущий SSH IP определен автоматически: $CLIENT_IP"

        while true; do
          redraw_acl_screen

          local item
          read_from_tty item "Ваш выбор [1/2/3/4]: " || return 1
          case "$item" in
            1)
              add_profile_marzban_host
              redraw_acl_screen
              ;;
            2)
              add_profile_marzban_node
              redraw_acl_screen
              ;;
            3)
              add_custom_rule
              redraw_acl_screen
              ;;
            4)
              if [[ "${#FW_RULE_NAMES[@]}" -eq 0 ]]; then
                print_warn "Список правил пуст. Добавьте минимум одно правило."
                continue
              fi
              break
              ;;
            *)
              print_warn "Введите 1, 2, 3 или 4."
              ;;
          esac

          local add_more
          read_from_tty add_more "Добавить еще правило/IP? [Y/n]: " || return 1
          add_more="${add_more:-Y}"
          case "$add_more" in
            n|N|no|NO)
              if [[ "${#FW_RULE_NAMES[@]}" -eq 0 ]]; then
                print_warn "Список правил пуст. Добавьте минимум одно правило."
              else
                break
              fi
              ;;
            *)
              ;;
          esac
        done

        rebuild_allowed_ips_csv
        break
        ;;
      *)
        print_warn "Введите 1 или 2."
        ;;
    esac
  done

  log "Access mode: $ACCESS_MODE; allowed=${ALLOWED_IPS_CSV:-ALL}; rules=${#FW_RULE_NAMES[@]}"
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "[DRY-RUN] sshd_config: $key $value"
    log "DRY-RUN sshd_config: $key $value"
    return 0
  fi

  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -ri "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|g" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi

  log "sshd_config set: $key $value"
}

is_user_logged_in() {
  local user="$1"
  who 2>/dev/null | awk '{print $1}' | grep -Fxq "$user"
}

ensure_deferred_delete_timer() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  mkdir -p "$DEFERRED_DELETE_DIR"

  cat > "$DEFERRED_DELETE_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail

LIST_FILE="/var/lib/vps-hardening/deferred_delete_users.list"
LOG_FILE="/var/log/vps_hardening.log"

touch "$LIST_FILE"

tmp_file="/tmp/vps_hardening_deferred_users.$$"
> "$tmp_file"

while IFS= read -r user; do
  [[ -z "$user" ]] && continue
  if ! id "$user" >/dev/null 2>&1; then
    continue
  fi

  if who 2>/dev/null | awk '{print $1}' | grep -Fxq "$user"; then
    echo "$user" >> "$tmp_file"
    echo "[$(date '+%F %T')] Deferred delete: user $user still logged in" >> "$LOG_FILE"
    continue
  fi

  if userdel -r "$user" >> "$LOG_FILE" 2>&1; then
    echo "[$(date '+%F %T')] Deferred delete: removed user $user" >> "$LOG_FILE"
  else
    echo "$user" >> "$tmp_file"
    echo "[$(date '+%F %T')] Deferred delete: failed for $user, will retry" >> "$LOG_FILE"
  fi
done < "$LIST_FILE"

mv "$tmp_file" "$LIST_FILE"

if [[ ! -s "$LIST_FILE" ]]; then
  systemctl disable --now vps-hardening-deferred-delete.timer >/dev/null 2>&1 || true
fi
EOF
  chmod 700 "$DEFERRED_DELETE_SCRIPT"

  cat > "$DEFERRED_DELETE_SERVICE" <<EOF
[Unit]
Description=Deferred user deletion for VPS hardening
After=network-online.target

[Service]
Type=oneshot
ExecStart=${DEFERRED_DELETE_SCRIPT}
User=root
Group=root
EOF

  cat > "$DEFERRED_DELETE_TIMER" <<EOF
[Unit]
Description=Retry deferred user deletion

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
Persistent=true
Unit=vps-hardening-deferred-delete.service

[Install]
WantedBy=timers.target
EOF

  run_cmd "systemctl daemon-reload" "Перечитывание systemd unit-файлов (deferred delete)"
  run_cmd "systemctl enable --now vps-hardening-deferred-delete.timer" "Включение таймера отложенного удаления пользователей"
}

enqueue_deferred_delete_user() {
  local user="$1"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "[DRY-RUN] Пользователь ${user} был бы добавлен в отложенное удаление"
    return 0
  fi

  ensure_deferred_delete_timer

  touch "$DEFERRED_DELETE_LIST"
  if ! grep -Fxq "$user" "$DEFERRED_DELETE_LIST"; then
    echo "$user" >> "$DEFERRED_DELETE_LIST"
  fi

  log "User scheduled for deferred deletion: $user"
}

safe_delete_user() {
  local user="$1"
  local action_label="$2"

  if [[ -z "$user" || "$user" == "root" ]]; then
    return 0
  fi

  if is_user_logged_in "$user"; then
    print_warn "Пользователь ${user} сейчас в активной сессии. Удаление отложено автоматически."
    enqueue_deferred_delete_user "$user"
    return 0
  fi

  run_cmd "userdel -r \"${user}\"" "$action_label"
}

prune_old_users() {
  local user
  while IFS=: read -r user _ uid _ _ _ shell; do
    if [[ "$uid" -lt 1000 ]]; then
      continue
    fi
    if [[ "$user" == "root" || "$user" == "$NEW_USER" || "$user" == "nobody" ]]; then
      continue
    fi
    if [[ "$shell" == */nologin || "$shell" == */false ]]; then
      continue
    fi

    backup_deleted_user "$user"
    safe_delete_user "$user" "Удаление старого пользователя ${user}"
  done < /etc/passwd
}

step_1_update_system() {
  print_step_header "1" "Обновление системы" "Закрываем известные уязвимости через обновление пакетов и ядра."
  run_cmd "apt update" "Обновление списка пакетов (apt update)"
  run_cmd "DEBIAN_FRONTEND=noninteractive apt upgrade -y" "Установка обновлений (apt upgrade -y)"
}

step_2_user_management() {
  print_step_header "2" "Создание пользователя" "Создаем отдельного sudo-пользователя и удаляем лишние пользовательские аккаунты."

  while true; do
    read_from_tty NEW_USER "Введите имя нового пользователя: " || return 1
    if validate_username "$NEW_USER"; then
      break
    fi
    print_warn "Недопустимое имя. Разрешены: буквы, цифры, дефис, нижнее подчеркивание."
  done

  NEW_USER_PASSWORD="$(gen_secret 16)"

  if id "$NEW_USER" >/dev/null 2>&1; then
    print_warn "Пользователь ${NEW_USER} уже существует, пароль будет обновлен."
  else
    run_cmd "adduser --disabled-password --gecos \"\" \"${NEW_USER}\"" "Создание пользователя ${NEW_USER}"
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s:%s\n' "$NEW_USER" "$NEW_USER_PASSWORD" | chpasswd
    log "Password updated for user: $NEW_USER"
  else
    print_warn "[DRY-RUN] Пропущена установка пароля пользователю ${NEW_USER}"
    log "DRY-RUN: skip set password for $NEW_USER"
  fi

  run_cmd "usermod -aG sudo \"${NEW_USER}\"" "Добавление ${NEW_USER} в группу sudo"
  run_cmd "id \"${NEW_USER}\"" "Проверка пользователя ${NEW_USER}"

  save_runtime_state

  prune_old_users

  echo
  echo "╔══════════════════════════════════════════════╗"
  echo "║   ДАННЫЕ ПОЛЬЗОВАТЕЛЯ (СОХРАНИТЕ ИХ)        ║"
  echo "╠══════════════════════════════════════════════╣"
  printf "║ User:     %-33s ║\n" "$NEW_USER"
  printf "║ Password: %-33s ║\n" "$NEW_USER_PASSWORD"
  echo "╚══════════════════════════════════════════════╝"
}

step_3_ssh_keys_auto() {
  print_step_header "3" "Автогенерация SSH-ключей" "Удаляем старые authorized_keys и создаем новый ed25519-ключ c надежной passphrase."

  SSH_KEY_PASSPHRASE="$(gen_secret 128)"

  local user_home="/home/${NEW_USER}"
  local ssh_dir="${user_home}/.ssh"
  local key_file="${ssh_dir}/id_ed25519"
  local pub_file="${ssh_dir}/id_ed25519.pub"
  local auth_file="${ssh_dir}/authorized_keys"

  run_cmd "mkdir -p \"${ssh_dir}\"" "Подготовка каталога .ssh"
  run_cmd "chown -R \"${NEW_USER}:${NEW_USER}\" \"${ssh_dir}\"" "Назначение владельца .ssh"
  run_cmd "chmod 700 \"${ssh_dir}\"" "Права 700 на .ssh"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    KEY_PASSPHRASE="$SSH_KEY_PASSPHRASE" runuser -u "$NEW_USER" -- bash -c '
      set -e
      umask 077
      rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub ~/.ssh/authorized_keys
      ssh-keygen -t ed25519 -C "example@example.com" -f ~/.ssh/id_ed25519 -N "$KEY_PASSPHRASE" -q
      cat ~/.ssh/id_ed25519.pub > ~/.ssh/authorized_keys
    '

    chmod 600 "$auth_file"
    chown "$NEW_USER:$NEW_USER" "$auth_file"

    SSH_PRIVATE_KEY_CONTENT="$(cat "$key_file")"
    SSH_PUBLIC_KEY_CONTENT="$(cat "$pub_file")"
    log "SSH keypair regenerated for user: $NEW_USER"
  else
    SSH_PRIVATE_KEY_CONTENT="<DRY-RUN: private key not generated>"
    SSH_PUBLIC_KEY_CONTENT="<DRY-RUN: public key not generated>"
    print_warn "[DRY-RUN] SSH-ключи не созданы"
    log "DRY-RUN: skip ssh key generation"
  fi
}

step_4_secure_ssh_access() {
  print_step_header "4" "Усиление SSH-доступа" "Отключаем root/password вход и переводим SSH на нестандартный порт."

  local input_port
  while true; do
    read_from_tty input_port "Введите новый SSH-порт [1024-65535, Enter = 2222]: " || return 1
    input_port="${input_port:-2222}"
    if validate_port "$input_port"; then
      SSH_PORT="$input_port"
      break
    fi
    print_warn "Порт должен быть в диапазоне 1024-65535."
  done

  local cfg="/etc/ssh/sshd_config"
  local bak="/etc/ssh/sshd_config.bak"

  if [[ ! -f "$bak" ]]; then
    run_cmd "cp \"${cfg}\" \"${bak}\"" "Создание бэкапа sshd_config"
  else
    print_warn "Бэкап уже существует: $bak"
  fi

  set_sshd_option "Port" "$SSH_PORT"
  set_sshd_option "PermitRootLogin" "no"
  set_sshd_option "PasswordAuthentication" "no"
  set_sshd_option "PubkeyAuthentication" "yes"
  set_sshd_option "AuthorizedKeysFile" ".ssh/authorized_keys"
  set_sshd_option "X11Forwarding" "no"
  set_sshd_option "MaxAuthTries" "3"
  set_sshd_option "LoginGraceTime" "20"

  save_runtime_state

  local sshd_bin
  sshd_bin="$(command -v sshd || true)"
  if [[ -z "$sshd_bin" ]]; then
    handle_error "Не найден sshd для проверки конфигурации."
    return 1
  fi

  run_cmd "\"${sshd_bin}\" -t" "Проверка синтаксиса sshd_config"

  get_server_ip
  echo
  print_info "Новая команда подключения: ssh ${NEW_USER}@${SERVER_IP} -p ${SSH_PORT}"
  print_warn "Текущую сессию не закрывайте до проверки нового входа."
}

step_5_configure_ufw() {
  print_step_header "5" "Настройка UFW" "Закрываем все входящие и открываем только SSH-порт по выбранной IP-модели."

  if ! command -v ufw >/dev/null 2>&1; then
    run_cmd "apt install -y ufw" "Установка UFW"
  fi

  run_cmd "ufw default deny incoming" "UFW: deny incoming"
  run_cmd "ufw default allow outgoing" "UFW: allow outgoing"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    run_cmd "ufw --force reset" "Сброс UFW для чистого применения актуальных правил"
    run_cmd "ufw default deny incoming" "UFW: deny incoming (после reset)"
    run_cmd "ufw default allow outgoing" "UFW: allow outgoing (после reset)"
  fi

  if [[ "$ACCESS_MODE" == "all" ]]; then
    run_cmd "ufw allow ${SSH_PORT}/tcp" "Разрешение SSH с любых IP"
  else
    local i src port name
    for ((i=0; i<${#FW_RULE_NAMES[@]}; i++)); do
      name="${FW_RULE_NAMES[$i]}"
      src="$(resolve_fw_source "${FW_RULE_SOURCES[$i]}")"
      port="$(resolve_fw_port "${FW_RULE_PORTS[$i]}")"

      validate_port "$port" || continue
      if [[ "$src" == "any" ]]; then
        run_cmd "ufw allow ${port}/tcp" "ACL ${name}: allow any -> tcp/${port}"
      else
        run_cmd "ufw allow from ${src} to any port ${port} proto tcp" "ACL ${name}: allow ${src} -> tcp/${port}"
      fi
    done
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    if ufw status | grep -q "Status: active"; then
      print_ok "UFW уже активен"
    else
      run_cmd "echo 'y' | ufw enable" "Включение UFW"
    fi
  else
    print_warn "[DRY-RUN] Пропущено включение UFW"
  fi

  run_cmd "ufw status verbose" "Проверка статуса UFW"
}

step_6_configure_fail2ban() {
  print_step_header "6" "Настройка Fail2ban" "Автоматический бан брутфорса: 24ч на первый раз, затем увеличение до постоянного."

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    run_cmd "apt install -y fail2ban" "Установка Fail2ban"
  fi

  get_client_ip
  local jail_file="/etc/fail2ban/jail.local"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    cat > "$jail_file" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${CLIENT_IP}
bantime  = 24h
findtime = 300
maxretry = 3

bantime.increment = true
bantime.factor = 2
bantime.maxtime = -1
bantime.overalljails = true

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
findtime = 300
bantime  = 24h
EOF
    chmod 644 "$jail_file"
    log "Updated $jail_file"
  else
    print_warn "[DRY-RUN] Пропущено обновление ${jail_file}"
    log "DRY-RUN: skip writing $jail_file"
  fi

  run_cmd "systemctl enable fail2ban" "Включение Fail2ban в автозагрузку"
  run_cmd "systemctl restart fail2ban" "Перезапуск Fail2ban"
  run_cmd "fail2ban-client status sshd" "Проверка Fail2ban jail sshd"
}

step_7_restart_ssh() {
  print_step_header "7" "Применение SSH-настроек" "Перезапускаем SSH-сервис и проверяем его состояние."
  run_cmd "systemctl restart ${SSH_SERVICE}" "Перезапуск SSH-сервиса (${SSH_SERVICE})"
  run_cmd "systemctl status ${SSH_SERVICE} --no-pager" "Проверка статуса SSH-сервиса (${SSH_SERVICE})"
}

step_8_setup_automation() {
  print_step_header "8" "Автообслуживание сервера" "Включаем автозапуск, автообновление системы и self-update скрипта."

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "[DRY-RUN] Пропущена настройка automation (systemd timer + self-update)"
    return 0
  fi

  local source_script="${BASH_SOURCE[0]:-}"
  if [[ -n "$source_script" && -f "$source_script" ]]; then
    install -m 700 "$source_script" "$INSTALLED_SCRIPT_PATH"
    log "Installed main script to: $INSTALLED_SCRIPT_PATH"
  else
    print_warn "Источник скрипта не файл (возможно запуск через pipe). Установлена только maintenance-логика."
    log "Script source path not file, skipped installing $INSTALLED_SCRIPT_PATH"
  fi

  cat > "$AUTOMATION_CONFIG_FILE" <<EOF
# VPS hardening automation config
SELF_UPDATE_ENABLED=1
SELF_UPDATE_URL="$DEFAULT_SELF_UPDATE_URL"
SYSTEM_AUTO_UPDATE_ENABLED=1
COMPONENT_AUTO_UPDATE_ENABLED=1
EOF
  chmod 600 "$AUTOMATION_CONFIG_FILE"
  log "Wrote automation config: $AUTOMATION_CONFIG_FILE"

  cat > "$MAINT_SCRIPT_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail

LOCK_FILE="/var/run/vps_hardening_maint.lock"
LOG_FILE="/var/log/vps_hardening_maintenance.log"
CONFIG_FILE="/etc/vps-hardening.conf"
TARGET_SCRIPT="/usr/local/sbin/vps_hardening.sh"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[$(date '+%F %T')] Another maintenance process is running" >> "$LOG_FILE"
  exit 0
fi

source_or_default() {
  local k="$1"
  local d="$2"
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  eval "echo \"\${$k:-$d}\""
}

SELF_UPDATE_ENABLED="$(source_or_default SELF_UPDATE_ENABLED 1)"
SELF_UPDATE_URL="$(source_or_default SELF_UPDATE_URL https://raw.githubusercontent.com/d4f1rz/vps-hardening/master/vps_hardening.sh)"
SYSTEM_AUTO_UPDATE_ENABLED="$(source_or_default SYSTEM_AUTO_UPDATE_ENABLED 1)"
COMPONENT_AUTO_UPDATE_ENABLED="$(source_or_default COMPONENT_AUTO_UPDATE_ENABLED 1)"

echo "[$(date '+%F %T')] Maintenance started" >> "$LOG_FILE"

if [[ "$SYSTEM_AUTO_UPDATE_ENABLED" == "1" ]]; then
  apt update >> "$LOG_FILE" 2>&1
  DEBIAN_FRONTEND=noninteractive apt upgrade -y >> "$LOG_FILE" 2>&1
  DEBIAN_FRONTEND=noninteractive apt autoremove -y >> "$LOG_FILE" 2>&1 || true
fi

if [[ "$COMPONENT_AUTO_UPDATE_ENABLED" == "1" ]]; then
  DEBIAN_FRONTEND=noninteractive apt install --only-upgrade -y fail2ban ufw openssh-server openssh-client >> "$LOG_FILE" 2>&1 || true
fi

if [[ "$SELF_UPDATE_ENABLED" == "1" ]]; then
  TMP_FILE="/tmp/vps_hardening.selfupdate.sh"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$SELF_UPDATE_URL" -o "$TMP_FILE" >> "$LOG_FILE" 2>&1 || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP_FILE" "$SELF_UPDATE_URL" >> "$LOG_FILE" 2>&1 || true
  fi

  if [[ -s "$TMP_FILE" ]] && bash -n "$TMP_FILE" >/dev/null 2>&1; then
    install -m 700 "$TMP_FILE" "$TARGET_SCRIPT"
    echo "[$(date '+%F %T')] Self-update applied to $TARGET_SCRIPT" >> "$LOG_FILE"
  else
    echo "[$(date '+%F %T')] Self-update skipped (download/syntax check failed)" >> "$LOG_FILE"
  fi
  rm -f "$TMP_FILE"
fi

echo "[$(date '+%F %T')] Maintenance finished" >> "$LOG_FILE"
EOF

  chmod 700 "$MAINT_SCRIPT_PATH"
  log "Wrote maintenance script: $MAINT_SCRIPT_PATH"

  cat > "$SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=VPS Hardening maintenance task
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${MAINT_SCRIPT_PATH}
User=root
Group=root
Nice=10
EOF

  cat > "$SYSTEMD_TIMER_FILE" <<EOF
[Unit]
Description=Run VPS Hardening maintenance periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=24h
Persistent=true
Unit=vps-hardening-maintenance.service

[Install]
WantedBy=timers.target
EOF

  run_cmd "systemctl daemon-reload" "Перечитывание systemd unit-файлов"
  run_cmd "systemctl enable --now vps-hardening-maintenance.timer" "Включение timer автозапуска обслуживания"
  run_cmd "systemctl status vps-hardening-maintenance.timer --no-pager" "Проверка timer обслуживания"

  save_runtime_state
}

step_9_final_report() {
  print_step_header "9" "Итоговый отчет" "Выводим все критичные данные для сохранения и подключения."
  get_server_ip
  get_client_ip

  local access_human
  if [[ "$ACCESS_MODE" == "all" ]]; then
    access_human="ALL"
  else
    access_human="SELECTED (${#FW_RULE_NAMES[@]} rules)"
  fi

  echo
  echo "╔════════════════════════════════════════════════════════════════════╗"
  echo "║                СОХРАНИТЕ ЭТИ ДАННЫЕ В НАДЕЖНОМ МЕСТЕ            ║"
  echo "╠════════════════════════════════════════════════════════════════════╣"
  printf "║ Server: %-58s ║\n" "${SERVER_IP}:${SSH_PORT}"
  printf "║ Connect: %-57s ║\n" "ssh ${NEW_USER}@${SERVER_IP} -p ${SSH_PORT}"
  printf "║ SSH Access Mode: %-49s ║\n" "$access_human"
  printf "║ Client IP (ignoreip): %-46s ║\n" "$CLIENT_IP"
  printf "║ User: %-60s ║\n" "$NEW_USER"
  printf "║ Password: %-56s ║\n" "$NEW_USER_PASSWORD"
  printf "║ Log file: %-56s ║\n" "$LOG_FILE"
  printf "║ Auto-maint log: %-51s ║\n" "$MAINT_LOG_FILE"
  printf "║ Auto-maint timer: %-48s ║\n" "vps-hardening-maintenance.timer"
  echo "╚════════════════════════════════════════════════════════════════════╝"

  if [[ "$ACCESS_MODE" == "selected" ]]; then
    echo
    echo "ACL таблица (актуальные правила):"
    echo "┌────┬────────────────────┬──────────────────────┬────────────┬───────────────────┐"
    echo "│ #  │ Name               │ Source               │ Port       │ Note              │"
    echo "├────┼────────────────────┼──────────────────────┼────────────┼───────────────────┤"
    local i src port
    for ((i=0; i<${#FW_RULE_NAMES[@]}; i++)); do
      src="$(resolve_fw_source "${FW_RULE_SOURCES[$i]}")"
      port="$(resolve_fw_port "${FW_RULE_PORTS[$i]}")"
      printf "│ %-2s │ %-18s │ %-20s │ %-10s │ %-17s │\n" "$((i+1))" "${FW_RULE_NAMES[$i]}" "$src" "$port" "${FW_RULE_NOTES[$i]}"
    done
    echo "└────┴────────────────────┴──────────────────────┴────────────┴───────────────────┘"
  fi

  echo
  echo "---------------------- SSH PRIVATE KEY ----------------------"
  echo "$SSH_PRIVATE_KEY_CONTENT"
  echo "---------------------- SSH PUBLIC KEY -----------------------"
  echo "$SSH_PUBLIC_KEY_CONTENT"
  echo "---------------------- SSH PASSPHRASE -----------------------"
  echo "$SSH_KEY_PASSPHRASE"

  echo
  print_warn "Не закрывайте текущую сессию, пока не проверите вход новой командой."
  print_info "После проверки можно удалить скрипт: rm -- \"$0\""

  log "FINAL: user=$NEW_USER port=$SSH_PORT access=$ACCESS_MODE client_ip=$CLIENT_IP"
  log "========== FINISH =========="
}

main() {
  parse_args "$@"
  check_root
  init_interactive_io
  init_log
  check_os
  detect_ssh_service
  detect_current_ssh_port

  if [[ "$ROLLBACK" -eq 1 ]]; then
    rollback_last
    exit 0
  fi

  show_banner

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "Режим --dry-run: изменения не будут применены."
  fi

  if ! ask_confirm "Начать автоматический hardening сейчас?"; then
    print_warn "Операция отменена пользователем."
    exit 0
  fi

  handle_reinstall_if_needed

  choose_access_mode
  init_backup_snapshot
  save_runtime_state

  step_1_update_system
  step_2_user_management
  step_3_ssh_keys_auto
  step_4_secure_ssh_access
  step_5_configure_ufw
  step_6_configure_fail2ban
  step_7_restart_ssh
  step_8_setup_automation
  step_9_final_report
}

main "$@"
