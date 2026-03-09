#!/bin/bash
# VPS Hardening Script
# Version: 1.0.0
# Compatibility: Ubuntu 20.04+ / Debian 11+

set -euo pipefail

VERSION="1.0.0"
LOG_FILE="/var/log/vps_hardening.log"
DRY_RUN=0

NEW_USER=""
SSH_PORT="2222"
SERVER_IP=""
SSH_SERVICE="sshd"

STEP_1_STATUS="⏭️ Пропущен"
STEP_2_STATUS="⏭️ Пропущен"
STEP_3_STATUS="⏭️ Пропущен"
STEP_4_STATUS="⏭️ Пропущен"
STEP_5_STATUS="⏭️ Пропущен"
STEP_6_STATUS="⏭️ Пропущен"
STEP_7_STATUS="⏭️ Пропущен"

C_RESET="\033[0m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_BOLD="\033[1m"

print_info() {
  echo -e "${C_BLUE}[INFO]${C_RESET} $*"
}

print_ok() {
  echo -e "${C_GREEN}[OK]${C_RESET} $*"
}

print_warn() {
  echo -e "${C_YELLOW}[WARN]${C_RESET} $*"
}

print_error() {
  echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

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
  bash vps_hardening.sh [--dry-run] [--help]

Опции:
  --dry-run   Показать, что будет выполнено, без реальных изменений.
  --help      Показать эту справку.

Описание:
  Интерактивный скрипт для базового hardening VPS на Ubuntu/Debian:
  - Обновление системы
  - Создание sudo-пользователя
  - Настройка SSH-ключей
  - Усиление SSH-конфига
  - Настройка UFW
  - Установка Fail2ban
EOF
}

ask_confirm() {
  local prompt="$1"
  local default_yes="${2:-Y}"
  local answer

  if [[ "$default_yes" == "Y" ]]; then
    read -r -p "$prompt [Y/n]: " answer
    answer="${answer:-Y}"
  else
    read -r -p "$prompt [y/N]: " answer
    answer="${answer:-N}"
  fi

  case "$answer" in
    Y|y|yes|YES) return 0 ;;
    N|n|no|NO) return 1 ;;
    *)
      print_warn "Некорректный ответ, используем значение по умолчанию."
      [[ "$default_yes" == "Y" ]]
      return
      ;;
  esac
}

pause_after_step() {
  local icon="$1"
  local text="$2"
  echo
  echo -e "${icon} ${text}"
  read -r -p "Нажмите Enter, чтобы продолжить... " _
}

handle_error() {
  local message="$1"
  print_error "$message"
  log "ERROR: $message"
  if ask_confirm "Продолжить выполнение несмотря на ошибку?" "N"; then
    log "User chose to continue after error"
    return 0
  fi
  log "User chose to exit after error"
  exit 1
}

show_spinner() {
  local pid="$1"
  local label="$2"
  local spin='|/-\\'
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\r${C_BLUE}[RUN]${C_RESET} %s %c" "$label" "${spin:$i:1}"
    sleep 0.12
  done
  printf "\r"
}

run_cmd() {
  local cmd="$1"
  print_info "Команда: $cmd"
  log "CMD: $cmd"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "[DRY-RUN] Команда не выполнена"
    log "DRY-RUN: skipped"
    return 0
  fi

  set +e
  bash -c "$cmd" >> "$LOG_FILE" 2>&1 &
  local pid=$!
  show_spinner "$pid" "$cmd"
  wait "$pid"
  local rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    handle_error "Команда завершилась с ошибкой (код: $rc): $cmd"
    return 1
  fi

  print_ok "Выполнено"
  return 0
}

validate_username() {
  local username="$1"
  [[ "$username" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ "$username" != "root" ]] || return 1
  return 0
}

validate_ssh_pubkey() {
  local key="$1"
  [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1024 && port <= 65535 )) || return 1
  return 0
}

is_port_in_use() {
  local port="$1"
  ss -tulnH 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"
}

get_current_sshd_port() {
  local sshd_bin
  sshd_bin="$(command -v sshd || true)"
  if [[ -z "$sshd_bin" ]]; then
    echo "22"
    return 0
  fi
  "$sshd_bin" -T 2>/dev/null | awk '/^port /{print $2; exit}'
}

detect_ssh_service() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    SSH_SERVICE="sshd"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    SSH_SERVICE="ssh"
  else
    SSH_SERVICE="sshd"
  fi
  log "Detected SSH service: $SSH_SERVICE"
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "[DRY-RUN] Установить в $file: $key $value"
    log "DRY-RUN: set sshd option $key $value"
    return 0
  fi

  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -ri "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|g" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi
  log "Updated sshd_config: $key $value"
}

check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    print_error "Скрипт должен быть запущен от root. Пример: sudo bash vps_hardening.sh"
    exit 1
  fi
}

check_os() {
  local id_like=""
  local id=""

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    id="${ID:-}"
    id_like="${ID_LIKE:-}"
  fi

  if [[ "$id" != "ubuntu" && "$id" != "debian" && "$id_like" != *"debian"* ]]; then
    print_warn "Обнаружена неподдерживаемая ОС: ID=${id:-unknown}, ID_LIKE=${id_like:-unknown}"
    log "Unsupported OS warning: ID=${id:-unknown}, ID_LIKE=${id_like:-unknown}"
    if ! ask_confirm "Продолжить на этой ОС на свой риск?" "N"; then
      exit 1
    fi
  else
    print_ok "ОС совместима: ${id:-unknown}"
    log "OS check passed: ${id:-unknown}"
  fi
}

show_banner() {
  cat <<'EOF'
╔═══════════════════════════════════════════╗
║     🔐 VPS HARDENING SCRIPT v1.0          ║
║     Автоматическая защита VPS-сервера     ║
╚═══════════════════════════════════════════╝

Будут выполнены следующие шаги:
  [1] Обновление системы
  [2] Создание sudo-пользователя
  [3] Настройка SSH-ключей
  [4] Конфигурация SSH-демона
  [5] Настройка файрвола UFW
  [6] Установка Fail2ban
  [7] Финальная проверка
EOF
}

step_1_update() {
  log "STEP 1 start: system update"
  run_cmd "apt update"
  run_cmd "DEBIAN_FRONTEND=noninteractive apt upgrade -y"
  log "STEP 1 done"
}

step_2_user() {
  log "STEP 2 start: create sudo user"

  while true; do
    read -r -p "Введите имя нового пользователя: " NEW_USER
    if ! validate_username "$NEW_USER"; then
      print_warn "Имя недопустимо. Используйте буквы/цифры/дефис/подчёркивание и не root."
      continue
    fi
    break
  done

  if id "$NEW_USER" >/dev/null 2>&1; then
    print_warn "Пользователь '$NEW_USER' уже существует. Будет использован существующий аккаунт."
    log "User exists: $NEW_USER"
  else
    local pass1
    local pass2
    while true; do
      read -r -s -p "Введите пароль (минимум 12 символов): " pass1
      echo
      read -r -s -p "Подтвердите пароль: " pass2
      echo

      if [[ "${#pass1}" -lt 12 ]]; then
        print_warn "Пароль слишком короткий."
        continue
      fi
      if [[ "$pass1" != "$pass2" ]]; then
        print_warn "Пароли не совпадают."
        continue
      fi
      break
    done

    read -r -p "Полное имя (можно пропустить): " full_name
    read -r -p "Телефон (можно пропустить): " phone
    read -r -p "Доп. поле (можно пропустить): " other

    local gecos
    gecos="${full_name},${other},${phone},"

    run_cmd "adduser --disabled-password --gecos \"${gecos}\" \"${NEW_USER}\""

    if [[ "$DRY_RUN" -eq 0 ]]; then
      printf '%s:%s\n' "$NEW_USER" "$pass1" | chpasswd
      log "Password set for user: $NEW_USER"
    else
      print_warn "[DRY-RUN] Пропущена установка пароля через chpasswd"
      log "DRY-RUN: skipped password setup"
    fi

    unset pass1 pass2
  fi

  run_cmd "usermod -aG sudo \"${NEW_USER}\""
  run_cmd "id \"${NEW_USER}\""
  log "STEP 2 done"
}

step_3_ssh_keys() {
  log "STEP 3 start: configure SSH keys"

  cat <<'EOF'

Как сгенерировать SSH-ключ:
  Linux/macOS:
    ssh-keygen -t ed25519 -C "your_email@example.com"
    cat ~/.ssh/id_ed25519.pub

  Windows PowerShell:
    ssh-keygen -t ed25519 -C "your_email@example.com"
    Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub

  Termius (GUI):
    Keychain -> Add Key -> Generate -> ED25519 -> Copy Public Key
EOF

  local pubkey
  while true; do
    read -r -p "Вставьте публичный SSH-ключ: " pubkey
    if validate_ssh_pubkey "$pubkey"; then
      break
    fi
    print_warn "Неверный формат ключа. Допустимо: ssh-ed25519 / ssh-rsa / ecdsa-sha2-*"
  done

  local ssh_dir="/home/${NEW_USER}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  run_cmd "mkdir -p \"${ssh_dir}\""

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "[DRY-RUN] Ключ не будет записан в ${auth_keys}"
    log "DRY-RUN: skipped writing authorized_keys"
  else
    touch "$auth_keys"
    if grep -Fqx "$pubkey" "$auth_keys"; then
      print_warn "Ключ уже присутствует в authorized_keys."
      log "SSH key already exists for user: $NEW_USER"
    else
      echo "$pubkey" >> "$auth_keys"
      print_ok "Публичный ключ добавлен."
      log "SSH key appended for user: $NEW_USER"
    fi
  fi

  run_cmd "chmod 700 \"${ssh_dir}\""
  run_cmd "chmod 600 \"${auth_keys}\""
  run_cmd "chown -R \"${NEW_USER}:${NEW_USER}\" \"${ssh_dir}\""

  log "STEP 3 done"
}

step_4_sshd() {
  log "STEP 4 start: configure sshd"

  local port_input
  local current_port
  current_port="$(get_current_sshd_port)"
  while true; do
    read -r -p "Введите новый SSH-порт [2222]: " port_input
    port_input="${port_input:-2222}"

    if ! validate_port "$port_input"; then
      print_warn "Порт должен быть числом от 1024 до 65535."
      continue
    fi

    if is_port_in_use "$port_input"; then
      if [[ "$port_input" == "$current_port" ]]; then
        print_warn "Порт ${port_input} уже используется текущим SSH. Оставляем без изменений."
      else
        print_warn "Порт ${port_input} уже занят. Выберите другой."
        continue
      fi
    fi

    SSH_PORT="$port_input"
    break
  done

  local sshd_config="/etc/ssh/sshd_config"
  local backup="/etc/ssh/sshd_config.bak"

  if [[ -f "$backup" ]]; then
    print_warn "Бэкап уже существует: $backup"
    log "Backup exists: $backup"
  else
    run_cmd "cp \"${sshd_config}\" \"${backup}\""
  fi

  set_sshd_option "Port" "$SSH_PORT"
  set_sshd_option "PermitRootLogin" "no"
  set_sshd_option "PasswordAuthentication" "no"
  set_sshd_option "PubkeyAuthentication" "yes"
  set_sshd_option "AuthorizedKeysFile" ".ssh/authorized_keys"
  set_sshd_option "X11Forwarding" "no"
  set_sshd_option "MaxAuthTries" "3"
  set_sshd_option "LoginGraceTime" "20"

  local sshd_bin
  sshd_bin="$(command -v sshd || true)"
  if [[ -z "$sshd_bin" ]]; then
    handle_error "Не найден бинарник sshd для проверки конфигурации."
    return 1
  fi

  run_cmd "\"${sshd_bin}\" -t"

  print_warn "Не закрывайте текущую сессию! Сначала убедитесь, что новое подключение работает."
  log "STEP 4 done"
}

step_5_ufw() {
  log "STEP 5 start: configure UFW"

  if ! command -v ufw >/dev/null 2>&1; then
    run_cmd "apt install -y ufw"
  else
    print_ok "UFW уже установлен."
    log "UFW already installed"
  fi

  run_cmd "ufw default deny incoming"
  run_cmd "ufw default allow outgoing"
  run_cmd "ufw allow ${SSH_PORT}/tcp"
  run_cmd "ufw allow 80/tcp"
  run_cmd "ufw allow 443/tcp"

  read -r -p "Открыть дополнительные TCP-порты? (через запятую, например 8080,3000) или Enter для пропуска: " extra_ports
  if [[ -n "${extra_ports}" ]]; then
    IFS=',' read -r -a ports <<< "$extra_ports"
    local p
    for p in "${ports[@]}"; do
      p="$(echo "$p" | xargs)"
      if validate_port "$p"; then
        run_cmd "ufw allow ${p}/tcp"
      else
        print_warn "Порт '${p}' пропущен: неверный формат или диапазон."
        log "Invalid extra port skipped: $p"
      fi
    done
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "[DRY-RUN] UFW не будет включён"
    log "DRY-RUN: skipped ufw enable"
  else
    if ufw status | grep -q "Status: active"; then
      print_ok "UFW уже активен."
      log "UFW already active"
    else
      run_cmd "echo 'y' | ufw enable"
    fi
  fi

  run_cmd "ufw status verbose"
  log "STEP 5 done"
}

step_6_fail2ban() {
  log "STEP 6 start: install/configure fail2ban"

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    run_cmd "apt install -y fail2ban"
  else
    print_ok "Fail2ban уже установлен."
    log "Fail2ban already installed"
  fi

  local jail_file="/etc/fail2ban/jail.local"
  local tmp_file="/tmp/jail.local.vps_hardening"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "[DRY-RUN] Пропущено создание ${jail_file}"
    log "DRY-RUN: skipped jail.local write"
  else
    cat > "$tmp_file" <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
bantime  = 86400
EOF
    mv "$tmp_file" "$jail_file"
    chmod 644 "$jail_file"
    log "jail.local written: $jail_file"
  fi

  run_cmd "systemctl enable fail2ban"
  run_cmd "systemctl start fail2ban"
  run_cmd "fail2ban-client status sshd"

  log "STEP 6 done"
}

step_7_final_checks() {
  log "STEP 7 start: restart/check SSH"
  run_cmd "systemctl restart ${SSH_SERVICE}"
  run_cmd "systemctl status ${SSH_SERVICE} --no-pager"
  log "STEP 7 done"
}

print_checklist() {
  echo
  echo "Финальный чеклист:"
  echo "  [1] Обновление системы      : ${STEP_1_STATUS}"
  echo "  [2] Создание пользователя   : ${STEP_2_STATUS}"
  echo "  [3] SSH-ключи               : ${STEP_3_STATUS}"
  echo "  [4] SSH-демон               : ${STEP_4_STATUS}"
  echo "  [5] UFW                     : ${STEP_5_STATUS}"
  echo "  [6] Fail2ban                : ${STEP_6_STATUS}"
  echo "  [7] Финальная проверка SSH  : ${STEP_7_STATUS}"
}

final_report() {
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  SERVER_IP="${SERVER_IP:-<IP_СЕРВЕРА>}"

  print_checklist
  echo
  echo "╔══════════════════════════════════════════════╗"
  echo "║        СОХРАНИТЕ ЭТИ ДАННЫЕ!                ║"
  echo "╠══════════════════════════════════════════════╣"
  printf "║ Пользователь: %-30s ║\n" "${NEW_USER:-<user>}"
  printf "║ SSH-порт:     %-30s ║\n" "${SSH_PORT:-2222}"
  printf "║ Команда:      %-30s ║\n" "ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP}"
  printf "║ Лог настройки: %-29s ║\n" "${LOG_FILE}"
  echo "╚══════════════════════════════════════════════╝"

  print_warn "ВАЖНО: Не закрывайте текущую сессию, пока не проверите новое подключение!"
  print_info "После проверки можно удалить скрипт: rm -- \"$0\""

  log "FINAL: user=${NEW_USER:-unknown}, port=${SSH_PORT:-unknown}, ip=${SERVER_IP}"
  log "========== FINISH =========="
}

run_step() {
  local step_num="$1"
  local title="$2"
  local func_name="$3"

  echo
  echo -e "${C_BOLD}Шаг ${step_num}: ${title}${C_RESET}"
  log "Prompt before step ${step_num}: ${title}"

  if ! ask_confirm "Выполнить этот шаг?" "Y"; then
    print_warn "Шаг ${step_num} пропущен пользователем."
    log "STEP ${step_num} skipped by user"
    return 2
  fi

  if "$func_name"; then
    print_ok "Шаг ${step_num} завершен"
    return 0
  else
    print_error "Шаг ${step_num} завершился с ошибкой"
    return 1
  fi
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
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

main() {
  parse_args "$@"
  check_root
  init_log
  check_os
  detect_ssh_service

  show_banner

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "Режим --dry-run активирован: изменения не будут применены."
  fi

  if ! ask_confirm "Начать выполнение скрипта?" "Y"; then
    print_warn "Отменено пользователем."
    exit 0
  fi

  set +e
  run_step "1" "Обновление системы" step_1_update
  local rc=$?
  set -e
  case "$rc" in
    0) STEP_1_STATUS="✅ Успешно"; pause_after_step "✅" "Шаг 1 завершён." ;;
    1) STEP_1_STATUS="❌ Ошибка"; pause_after_step "❌" "Шаг 1 завершён с ошибкой." ;;
    2) STEP_1_STATUS="⏭️ Пропущен"; pause_after_step "⏭️" "Шаг 1 пропущен." ;;
  esac

  set +e
  run_step "2" "Создание sudo-пользователя" step_2_user
  rc=$?
  set -e
  case "$rc" in
    0) STEP_2_STATUS="✅ Успешно"; pause_after_step "✅" "Шаг 2 завершён." ;;
    1) STEP_2_STATUS="❌ Ошибка"; pause_after_step "❌" "Шаг 2 завершён с ошибкой." ;;
    2) STEP_2_STATUS="⏭️ Пропущен"; pause_after_step "⏭️" "Шаг 2 пропущен." ;;
  esac

  if [[ -z "$NEW_USER" ]]; then
    STEP_3_STATUS="⏭️ Пропущен"
    print_warn "Шаг 3 пропущен: не задан пользователь из шага 2."
    log "STEP 3 skipped: NEW_USER is empty"
    pause_after_step "⏭️" "Шаг 3 пропущен (нет пользователя)."
  else
    set +e
    run_step "3" "Настройка SSH-ключей" step_3_ssh_keys
    rc=$?
    set -e
    case "$rc" in
      0) STEP_3_STATUS="✅ Успешно"; pause_after_step "✅" "Шаг 3 завершён." ;;
      1) STEP_3_STATUS="❌ Ошибка"; pause_after_step "❌" "Шаг 3 завершён с ошибкой." ;;
      2) STEP_3_STATUS="⏭️ Пропущен"; pause_after_step "⏭️" "Шаг 3 пропущен." ;;
    esac
  fi

  set +e
  run_step "4" "Настройка SSH-демона" step_4_sshd
  rc=$?
  set -e
  case "$rc" in
    0) STEP_4_STATUS="✅ Успешно"; pause_after_step "✅" "Шаг 4 завершён." ;;
    1) STEP_4_STATUS="❌ Ошибка"; pause_after_step "❌" "Шаг 4 завершён с ошибкой." ;;
    2) STEP_4_STATUS="⏭️ Пропущен"; pause_after_step "⏭️" "Шаг 4 пропущен." ;;
  esac

  set +e
  run_step "5" "Настройка UFW" step_5_ufw
  rc=$?
  set -e
  case "$rc" in
    0) STEP_5_STATUS="✅ Успешно"; pause_after_step "✅" "Шаг 5 завершён." ;;
    1) STEP_5_STATUS="❌ Ошибка"; pause_after_step "❌" "Шаг 5 завершён с ошибкой." ;;
    2) STEP_5_STATUS="⏭️ Пропущен"; pause_after_step "⏭️" "Шаг 5 пропущен." ;;
  esac

  set +e
  run_step "6" "Установка и настройка Fail2ban" step_6_fail2ban
  rc=$?
  set -e
  case "$rc" in
    0) STEP_6_STATUS="✅ Успешно"; pause_after_step "✅" "Шаг 6 завершён." ;;
    1) STEP_6_STATUS="❌ Ошибка"; pause_after_step "❌" "Шаг 6 завершён с ошибкой." ;;
    2) STEP_6_STATUS="⏭️ Пропущен"; pause_after_step "⏭️" "Шаг 6 пропущен." ;;
  esac

  set +e
  run_step "7" "Перезапуск SSH и финальная проверка" step_7_final_checks
  rc=$?
  set -e
  case "$rc" in
    0) STEP_7_STATUS="✅ Успешно"; pause_after_step "✅" "Шаг 7 завершён." ;;
    1) STEP_7_STATUS="❌ Ошибка"; pause_after_step "❌" "Шаг 7 завершён с ошибкой." ;;
    2) STEP_7_STATUS="⏭️ Пропущен"; pause_after_step "⏭️" "Шаг 7 пропущен." ;;
  esac

  final_report
}

main "$@"
