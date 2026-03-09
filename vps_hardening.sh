#!/bin/bash
# VPS Hardening Script
# Version: 1.1.0
# Compatibility: Ubuntu 20.04+ / Debian 11+

set -euo pipefail

VERSION="1.1.0"
LOG_FILE="/var/log/vps_hardening.log"
DRY_RUN=0

NEW_USER=""
NEW_USER_PASSWORD=""
SSH_PORT="2222"
SSH_SERVICE="sshd"
SERVER_IP=""
CLIENT_IP=""

ACCESS_MODE="all"     # all | selected
ALLOWED_IPS_CSV=""

SSH_PRIVATE_KEY_CONTENT=""
SSH_PUBLIC_KEY_CONTENT=""
SSH_KEY_PASSPHRASE=""

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
  bash vps_hardening.sh [--dry-run] [--help]

Опции:
  --dry-run   Симуляция без реальных изменений.
  --help      Показать справку.

Что делает скрипт:
  1) Обновляет систему
  2) Создает нового sudo-пользователя
  3) Удаляет старых пользователей (кроме root и нового)
  4) Генерирует SSH-ключи автоматически
  5) Усиливает SSH-конфиг
  6) Настраивает UFW (доступ: всем или только выбранным IP)
  7) Настраивает Fail2ban
  8) Перезапускает SSH и показывает итоговый отчет
EOF
}

ask_confirm() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [Y/n]: " answer
  answer="${answer:-Y}"
  case "$answer" in
    Y|y|yes|YES) return 0 ;;
    N|n|no|NO) return 1 ;;
    *) return 0 ;;
  esac
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
║            VPS HARDENING SCRIPT v1.1.0                  ║
║     Автоматическая защита VPS (Ubuntu/Debian)           ║
╚══════════════════════════════════════════════════════════╝
EOF
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
  LC_ALL=C tr -dc "$chars" < /dev/urandom | head -c "$len"
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

get_server_ip() {
  SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  SERVER_IP="${SERVER_IP:-<IP_СЕРВЕРА>}"
}

get_client_ip() {
  CLIENT_IP="$(echo "${SSH_CONNECTION:-}" | awk '{print $1}')"
  if [[ -z "$CLIENT_IP" ]]; then
    CLIENT_IP="$(who am i 2>/dev/null | awk '{print $5}' | tr -d '()')"
  fi
  CLIENT_IP="${CLIENT_IP:-127.0.0.1}"
  log "Client IP detected: $CLIENT_IP"
}

choose_access_mode() {
  echo
  echo "Выберите модель доступа по IP для SSH:"
  echo "  1) Разрешить вход с любых IP"
  echo "  2) Разрешить вход только с выбранных IP/CIDR"

  local choice
  while true; do
    read -r -p "Ваш выбор [1/2]: " choice
    case "$choice" in
      1)
        ACCESS_MODE="all"
        break
        ;;
      2)
        ACCESS_MODE="selected"
        while true; do
          read -r -p "Введите IP/CIDR через запятую (пример: 1.2.3.4,5.6.7.0/24): " ALLOWED_IPS_CSV
          if [[ -z "$ALLOWED_IPS_CSV" ]]; then
            print_warn "Список не может быть пустым для режима selected."
            continue
          fi

          local valid=1
          local item
          IFS=',' read -r -a items <<< "$ALLOWED_IPS_CSV"
          for item in "${items[@]}"; do
            item="$(echo "$item" | xargs)"
            if ! validate_ip_or_cidr "$item"; then
              valid=0
              print_warn "Некорректный IP/CIDR: $item"
              break
            fi
          done

          if [[ "$valid" -eq 1 ]]; then
            break
          fi
        done
        break
        ;;
      *)
        print_warn "Введите 1 или 2."
        ;;
    esac
  done

  log "Access mode: $ACCESS_MODE; allowed=${ALLOWED_IPS_CSV:-ALL}"
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

    run_cmd "userdel -r \"${user}\"" "Удаление старого пользователя ${user}"
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
    read -r -p "Введите имя нового пользователя: " NEW_USER
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
    read -r -p "Введите новый SSH-порт [1024-65535, Enter = 2222]: " input_port
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

  if [[ "$ACCESS_MODE" == "all" ]]; then
    run_cmd "ufw allow ${SSH_PORT}/tcp" "Разрешение SSH с любых IP"
  else
    local ip
    IFS=',' read -r -a ips <<< "$ALLOWED_IPS_CSV"
    for ip in "${ips[@]}"; do
      ip="$(echo "$ip" | xargs)"
      run_cmd "ufw allow from ${ip} to any port ${SSH_PORT} proto tcp" "Разрешение SSH только с ${ip}"
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

step_8_final_report() {
  print_step_header "8" "Итоговый отчет" "Выводим все критичные данные для сохранения и подключения."
  get_server_ip
  get_client_ip

  local access_human
  if [[ "$ACCESS_MODE" == "all" ]]; then
    access_human="ALL"
  else
    access_human="$ALLOWED_IPS_CSV"
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
  echo "╚════════════════════════════════════════════════════════════════════╝"

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
  init_log
  check_os
  detect_ssh_service

  show_banner

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_warn "Режим --dry-run: изменения не будут применены."
  fi

  if ! ask_confirm "Начать автоматический hardening сейчас?"; then
    print_warn "Операция отменена пользователем."
    exit 0
  fi

  choose_access_mode

  step_1_update_system
  step_2_user_management
  step_3_ssh_keys_auto
  step_4_secure_ssh_access
  step_5_configure_ufw
  step_6_configure_fail2ban
  step_7_restart_ssh
  step_8_final_report
}

main "$@"
