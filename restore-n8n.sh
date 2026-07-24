#!/usr/bin/env bash
set -Eeuo pipefail

# Interactive disaster-recovery bootstrap for an n8n Selfhost AI installation.
# This file intentionally contains no infrastructure secrets.

SCRIPT_VERSION="1.4.1"
EXPECTED_UBUNTU_VERSION="24.04"

SELFHOST_DIR="/root/selfhost-ai"
PLAYWRIGHT_DIR="/opt/playwright"
RECOVERY_BASE="/srv/n8n-recovery"
PASSWORD_DIR="/root/.config/n8n-backup"
PASSWORD_FILE="${PASSWORD_DIR}/restic-password"

SFTP_PASSWORD_FILE=""
TEMP_KNOWN_HOSTS=""
LOG_FILE=""
SNAPSHOT_JSON_FILE=""
ENV_TEMP_FILE=""
POSTGRES_RESTORE_PID=""
TELEGRAM_WORKFLOWS_FILE="/tmp/n8n-recovery-telegram-workflows.json"
TELEGRAM_CREDENTIALS_FILE="/tmp/n8n-recovery-telegram-credentials.json"
N8N_PUBLIC_HOSTNAME=""
N8N_PUBLIC_ORIGIN=""

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET=""
  C_BOLD=""
  C_BLUE=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
fi

title() {
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
}

step() {
  printf '\n%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$1"
}

ok() {
  printf '%sOK:%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

warn() {
  printf '%sWARNING:%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2
}

fail() {
  printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$POSTGRES_RESTORE_PID" ]] && \
     kill -0 "$POSTGRES_RESTORE_PID" 2>/dev/null; then
    kill "$POSTGRES_RESTORE_PID" 2>/dev/null || true
    wait "$POSTGRES_RESTORE_PID" 2>/dev/null || true
  fi

  [[ -n "$SFTP_PASSWORD_FILE" ]] && rm -f -- "$SFTP_PASSWORD_FILE"
  [[ -n "$TEMP_KNOWN_HOSTS" ]] && rm -f -- "$TEMP_KNOWN_HOSTS"
  [[ -n "$SNAPSHOT_JSON_FILE" ]] && rm -f -- "$SNAPSHOT_JSON_FILE"
  [[ -n "$ENV_TEMP_FILE" ]] && rm -f -- "$ENV_TEMP_FILE"

  if command -v docker >/dev/null 2>&1 && \
     docker inspect n8n >/dev/null 2>&1; then
    docker exec n8n rm -f -- \
      "$TELEGRAM_WORKFLOWS_FILE" \
      "$TELEGRAM_CREDENTIALS_FILE" >/dev/null 2>&1 || true
  fi
}

on_error() {
  local exit_code=$?
  local line_number=${1:-unknown}
  printf '\n%sERROR:%s recovery stopped at line %s (exit code %s).\n' \
    "$C_RED" "$C_RESET" "$line_number" "$exit_code" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf 'Log file: %s\n' "$LOG_FILE" >&2
  fi
  exit "$exit_code"
}

trap cleanup EXIT
trap 'on_error $LINENO' ERR

confirm() {
  local prompt=$1
  local default=${2:-no}
  local suffix="[y/N]"
  local answer

  [[ "$default" == "yes" ]] && suffix="[Y/n]"
  read -r -p "$prompt $suffix " answer
  answer=${answer:-$default}

  [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss]|[Дд]|[Дд][Аа])$ ]]
}

read_default() {
  local variable_name=$1
  local prompt=$2
  local default_value=$3
  local answer

  read -r -p "$prompt [$default_value]: " answer
  printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

require_root() {
  [[ "$EUID" -eq 0 ]] || fail "Run this script as root: sudo bash restore-n8n.sh"
}

require_fresh_host() {
  if [[ -e "$SELFHOST_DIR" ]]; then
    fail "$SELFHOST_DIR already exists. This script only restores to a fresh VPS."
  fi

  if command -v docker >/dev/null 2>&1 && \
    docker ps -a --format '{{.Names}}' 2>/dev/null | \
      grep -Eq '^(n8n|postgres|redis|playwright|n8n-worker-1|n8n-runner-1)$'; then
    fail "n8n-related containers already exist. Refusing to overwrite a running installation."
  fi
}

load_os_release() {
  [[ -r /etc/os-release ]] || fail "/etc/os-release is missing."
  # shellcheck disable=SC1091
  source /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || fail "Only Ubuntu is supported by this bootstrap."
  [[ "$(uname -m)" == "x86_64" ]] || \
    fail "This backup was created on amd64; the recovery VPS must use x86_64/amd64."

  if [[ "${VERSION_ID:-}" != "$EXPECTED_UBUNTU_VERSION" ]]; then
    warn "The backup was designed for Ubuntu ${EXPECTED_UBUNTU_VERSION}; this host uses ${VERSION_ID:-unknown}."
    confirm "Continue with this Ubuntu version?" "no" || exit 0
  fi
}

install_base_packages() {
  step "Installing base recovery tools"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    gzip \
    jq \
    openssh-client \
    restic \
    sshpass
  ok "Base recovery tools are installed."
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker Engine and Docker Compose are already installed."
    return
  fi

  step "Installing Docker Engine from Docker's official Ubuntu repository"

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  local ubuntu_codename
  ubuntu_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME}}"

  printf '%s\n' \
    'Types: deb' \
    'URIs: https://download.docker.com/linux/ubuntu' \
    "Suites: ${ubuntu_codename}" \
    'Components: stable' \
    "Architectures: $(dpkg --print-architecture)" \
    'Signed-By: /etc/apt/keyrings/docker.asc' \
    > /etc/apt/sources.list.d/docker.sources

  apt-get update
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker
  docker version >/dev/null
  docker compose version >/dev/null
  ok "Docker Engine and Docker Compose are installed."
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    ok "Tailscale is already installed."
  else
    step "Installing Tailscale using its official Linux installer"
    local installer
    installer=$(mktemp /tmp/tailscale-install.XXXXXX.sh)
    curl -fsSL https://tailscale.com/install.sh -o "$installer"
    sh "$installer"
    rm -f -- "$installer"
  fi

  systemctl enable --now tailscaled

  if ! tailscale ip -4 2>/dev/null | grep -q '^100\.'; then
    title "Tailscale login required"
    printf '%s\n' \
      "A login URL will be displayed." \
      "Open it in a browser and sign in to the same tailnet as your Synology." \
      "Return here after authorization."
    tailscale up
  fi

  tailscale status >/dev/null
  ok "This VPS is connected to Tailscale."
  warn "After recovery, disable key expiry for this VPS in the Tailscale Machines console."
}

collect_repository_settings() {
  title "Synology and Restic settings"
  printf '%s\n' "Enter the values used by the backup system. No values are uploaded anywhere."

  read_default NAS_HOST \
    "Synology Tailscale IP or MagicDNS name" \
    "homenas"
  read_default SFTP_USER \
    "Synology SFTP user" \
    "n8n_backup"
  read_default RESTIC_REMOTE_PATH \
    "Restic repository path on Synology" \
    "/n8n-backups/restic-n8n"

  REPOSITORY="sftp:${SFTP_USER}@${NAS_HOST}:${RESTIC_REMOTE_PATH}"

  step "Checking Synology over Tailscale"
  tailscale ping "$NAS_HOST"
  ok "Synology is reachable over Tailscale."
}

collect_passwords() {
  install -d -m 700 "$PASSWORD_DIR"

  title "Restic password"
  printf '%s\n' "Enter the Restic password stored outside the lost VPS."
  local restic_password
  read -r -s -p "Restic password: " restic_password
  printf '\n'
  [[ -n "$restic_password" ]] || fail "Restic password cannot be empty."
  printf '%s\n' "$restic_password" > "$PASSWORD_FILE"
  unset restic_password
  chmod 600 "$PASSWORD_FILE"

  title "Synology SFTP password"
  printf '%s\n' \
    "The SFTP password is kept only in /run (RAM) during recovery" \
    "and is deleted automatically when the script exits."
  local sftp_password
  read -r -s -p "SFTP password for ${SFTP_USER}: " sftp_password
  printf '\n'
  [[ -n "$sftp_password" ]] || fail "SFTP password cannot be empty."
  SFTP_PASSWORD_FILE=$(mktemp /run/n8n-recovery-sftp.XXXXXX)
  printf '%s\n' "$sftp_password" > "$SFTP_PASSWORD_FILE"
  unset sftp_password
  chmod 600 "$SFTP_PASSWORD_FILE"
}

verify_ssh_host_key() {
  step "Reading the Synology SSH host key"
  TEMP_KNOWN_HOSTS=$(mktemp /run/n8n-recovery-known-hosts.XXXXXX)
  ssh-keyscan -T 10 "$NAS_HOST" > "$TEMP_KNOWN_HOSTS" 2>/dev/null
  [[ -s "$TEMP_KNOWN_HOSTS" ]] || fail "Could not read the Synology SSH host key."

  printf '\nSynology SSH fingerprints:\n'
  ssh-keygen -lf "$TEMP_KNOWN_HOSTS"
  printf '\n'
  warn "Confirm these fingerprints belong to your Synology."
  read -r -p "Type YES to trust this Synology: " trust_answer
  [[ "$trust_answer" == "YES" ]] || fail "SSH host key was not confirmed."
}

prepare_restic_command() {
  local ssh_command
  ssh_command="sshpass -f ${SFTP_PASSWORD_FILE} ssh"
  ssh_command+=" -o UserKnownHostsFile=${TEMP_KNOWN_HOSTS}"
  ssh_command+=" -o StrictHostKeyChecking=yes"
  ssh_command+=" -o PreferredAuthentications=password"
  ssh_command+=" -o PubkeyAuthentication=no"
  ssh_command+=" -l ${SFTP_USER} ${NAS_HOST} -s sftp"

  RESTIC=(
    restic
    -r "$REPOSITORY"
    --password-file "$PASSWORD_FILE"
    -o "sftp.command=${ssh_command}"
  )
}

select_snapshot() {
  step "Opening the Restic repository"
  SNAPSHOT_JSON_FILE=$(mktemp /run/n8n-recovery-snapshots.XXXXXX.json)
  "${RESTIC[@]}" snapshots --json > "$SNAPSHOT_JSON_FILE"

  local snapshot_count
  snapshot_count=$(jq 'length' "$SNAPSHOT_JSON_FILE")
  (( snapshot_count > 0 )) || fail "The Restic repository contains no snapshots."

  local display_count=10
  (( snapshot_count < display_count )) && display_count=$snapshot_count

  mapfile -t SNAPSHOT_IDS < <(
    jq -r 'sort_by(.time) | reverse | .[:10] | .[].id' "$SNAPSHOT_JSON_FILE"
  )
  mapfile -t SNAPSHOT_TIMES < <(
    jq -r 'sort_by(.time) | reverse | .[:10] | .[].time' "$SNAPSHOT_JSON_FILE"
  )
  mapfile -t SNAPSHOT_TAGS < <(
    jq -r 'sort_by(.time) | reverse | .[:10] | .[] | ((.tags // []) | join(","))' \
      "$SNAPSHOT_JSON_FILE"
  )

  step "Calculating restore sizes for the ${display_count} newest snapshots"
  printf '\nLatest backup snapshots (time zone: Europe/Moscow):\n'
  printf '  %-3s %-16s  %-9s  %-14s  %-8s\n' "No." "Date and time" "Size" "Tag" "ID"
  printf '  %-3s %-16s  %-9s  %-14s  %-8s\n' "---" "----------------" "---------" "--------------" "--------"

  local index snapshot_time snapshot_tag stats_json total_size human_size latest_mark
  for (( index=0; index<display_count; index++ )); do
    snapshot_time=$(TZ=Europe/Moscow date -d "${SNAPSHOT_TIMES[$index]}" '+%Y-%m-%d %H:%M')
    snapshot_tag=${SNAPSHOT_TAGS[$index]:--}
    snapshot_tag=${snapshot_tag:0:14}
    human_size="unknown"

    if stats_json=$("${RESTIC[@]}" stats --mode restore-size --json \
        "${SNAPSHOT_IDS[$index]}" 2>/dev/null); then
      total_size=$(jq -r '.total_size // 0' <<< "$stats_json")
      human_size=$(numfmt --to=iec-i --suffix=B "$total_size" 2>/dev/null || printf '%sB' "$total_size")
    fi

    latest_mark=""
    (( index == 0 )) && latest_mark=" latest"
    printf '  %-3s %-16s  %-9s  %-14s  %.8s%s\n' \
      "$((index + 1)))" "$snapshot_time" "$human_size" "$snapshot_tag" \
      "${SNAPSHOT_IDS[$index]}" "$latest_mark"
  done

  printf '\nHow to choose:\n'
  printf '  Enter          newest snapshot (latest)\n'
  printf '  1-%s            snapshot number from the table\n' "$display_count"
  printf '  YYYY-MM-DD     newest snapshot from that date, including dates not shown above\n\n'

  local selection selected_time
  while true; do
    read -r -p "Choose latest, number 1-${display_count}, or date YYYY-MM-DD [latest]: " selection
    selection=${selection:-latest}

    if [[ "$selection" == "latest" ]]; then
      SNAPSHOT_ID=${SNAPSHOT_IDS[0]}
      break
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] && \
       (( selection >= 1 && selection <= display_count )); then
      SNAPSHOT_ID=${SNAPSHOT_IDS[$((selection - 1))]}
      break
    fi

    if [[ "$selection" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      SNAPSHOT_ID=$(jq -r --arg selected_date "$selection" \
        'map(select(.time[0:10] == $selected_date)) | sort_by(.time) | reverse | .[0].id // empty' \
        "$SNAPSHOT_JSON_FILE")
      if [[ -n "$SNAPSHOT_ID" ]]; then
        break
      fi
      warn "No snapshot was found for ${selection}."
      continue
    fi

    warn "Invalid selection. Press Enter, enter a table number, or use YYYY-MM-DD."
  done

  selected_time=$(jq -r --arg id "$SNAPSHOT_ID" \
    'map(select(.id == $id)) | .[0].time' "$SNAPSHOT_JSON_FILE")
  selected_time=$(TZ=Europe/Moscow date -d "$selected_time" '+%Y-%m-%d %H:%M:%S %Z')
  ok "Selected snapshot ${SNAPSHOT_ID:0:8} from ${selected_time}."

  if confirm "Run a repository integrity check before restore?" "yes"; then
    step "Checking Restic repository integrity"
    "${RESTIC[@]}" check
    ok "Restic found no repository errors."
  fi
}

restore_snapshot() {
  RECOVERY_RUN="${RECOVERY_BASE}/$(date +%Y%m%d-%H%M%S)"
  install -d -m 700 "$RECOVERY_RUN"

  step "Restoring snapshot ${SNAPSHOT_ID}"
  "${RESTIC[@]}" restore "$SNAPSHOT_ID" --target "$RECOVERY_RUN"

  RESTORED_SELFHOST="${RECOVERY_RUN}/root/selfhost-ai"
  RESTORED_DUMP="${RECOVERY_RUN}/var/backups/n8n-staging/postgres-all.sql.gz"
  RESTORED_N8N_DATA=""
  RESTORED_PLAYWRIGHT=""
  RESTORED_PORTAINER_DATA=""
  RESTORED_CADDY_CONFIG=""
  RESTORED_CADDY_DATA=""
  RESTORED_GRAFANA_DATA=""
  RESTORED_PROMETHEUS_DATA=""
  RESTORED_DATABASUS_DATA=""

  local n8n_candidate
  for n8n_candidate in \
    "${RECOVERY_RUN}/var/lib/docker/volumes/localai_n8n_storage/_data" \
    "${RECOVERY_RUN}/var/lib/docker/volumes/selfhost-ai_n8n_storage/_data"
  do
    if [[ -d "$n8n_candidate" ]]; then
      RESTORED_N8N_DATA="$n8n_candidate"
      break
    fi
  done

  local support_volume_candidate
  support_volume_candidate="${RECOVERY_RUN}/var/lib/docker/volumes/localai_portainer_data/_data"
  [[ -d "$support_volume_candidate" ]] && \
    RESTORED_PORTAINER_DATA="$support_volume_candidate"

  support_volume_candidate="${RECOVERY_RUN}/var/lib/docker/volumes/localai_caddy-config/_data"
  [[ -d "$support_volume_candidate" ]] && \
    RESTORED_CADDY_CONFIG="$support_volume_candidate"

  support_volume_candidate="${RECOVERY_RUN}/var/lib/docker/volumes/localai_caddy-data/_data"
  [[ -d "$support_volume_candidate" ]] && \
    RESTORED_CADDY_DATA="$support_volume_candidate"

  support_volume_candidate="${RECOVERY_RUN}/var/lib/docker/volumes/localai_grafana/_data"
  [[ -d "$support_volume_candidate" ]] && \
    RESTORED_GRAFANA_DATA="$support_volume_candidate"

  support_volume_candidate="${RECOVERY_RUN}/var/lib/docker/volumes/localai_prometheus_data/_data"
  [[ -d "$support_volume_candidate" ]] && \
    RESTORED_PROMETHEUS_DATA="$support_volume_candidate"

  support_volume_candidate="${RECOVERY_RUN}/var/lib/docker/volumes/localai_databasus_data/_data"
  [[ -d "$support_volume_candidate" ]] && \
    RESTORED_DATABASUS_DATA="$support_volume_candidate"

  local playwright_candidate
  for playwright_candidate in \
    "${RECOVERY_RUN}/var/lib/docker/volumes/localai_portainer_data/_data/compose/1" \
    "${RECOVERY_RUN}/opt/playwright"
  do
    if [[ -f "${playwright_candidate}/docker-compose.yml" && \
          -f "${playwright_candidate}/stack.env" ]]; then
      RESTORED_PLAYWRIGHT="$playwright_candidate"
      break
    fi
  done

  [[ -d "$RESTORED_SELFHOST" ]] || fail "Selfhost AI project is missing from the snapshot."
  [[ -s "$RESTORED_DUMP" ]] || fail "PostgreSQL dump is missing or empty."
  [[ -n "$RESTORED_N8N_DATA" && -d "$RESTORED_N8N_DATA" ]] || \
    fail "n8n volume data is missing."
  [[ -n "$RESTORED_PLAYWRIGHT" ]] || fail "Playwright configuration is missing."

  gzip -t "$RESTORED_DUMP"
  ok "Snapshot files passed validation."
}

unquote_env_value() {
  local value=$1

  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value=${value:1:${#value}-2}
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value=${value:1:${#value}-2}
  fi

  printf '%s' "$value"
}

read_env_value() {
  local variable_name=$1
  local env_file=$2
  local value

  value=$(sed -n "s/^${variable_name}=//p" "$env_file" | tail -n 1)
  unquote_env_value "$value"
}

valid_hostname() {
  local hostname=$1
  local label
  local -a labels

  [[ -n "$hostname" && ${#hostname} -le 253 ]] || return 1
  [[ "$hostname" == *.* ]] || return 1
  [[ "$hostname" != .* && "$hostname" != *. && "$hostname" != *..* ]] || return 1

  IFS=. read -r -a labels <<< "$hostname"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
  done
}

configure_public_domain() {
  local env_file="${SELFHOST_DIR}/.env"
  local old_n8n_hostname
  local old_base_domain
  local new_base_domain
  local variable_name
  local raw_value
  local current_hostname
  local new_hostname
  local prefix
  local line
  local confirmation
  local replacement_found
  local -a hostname_variables=()
  local -a old_hostnames=()
  local -a new_hostnames=()

  old_n8n_hostname=$(read_env_value N8N_HOSTNAME "$env_file")
  valid_hostname "$old_n8n_hostname" || \
    fail "N8N_HOSTNAME in the restored .env is missing or invalid."

  old_n8n_hostname=${old_n8n_hostname,,}
  old_base_domain=${old_n8n_hostname#*.}

  title "Public domain settings"
  printf '%s\n' \
    "Enter the base domain that all restored public service hostnames should use." \
    "Press Enter to keep every restored hostname unchanged."
  read_default new_base_domain "Public base domain" "$old_base_domain"
  new_base_domain=${new_base_domain,,}

  valid_hostname "$new_base_domain" || \
    fail "The public base domain is not a valid DNS hostname."

  if [[ "$new_base_domain" == "$old_base_domain" ]]; then
    N8N_PUBLIC_HOSTNAME="$old_n8n_hostname"
    N8N_PUBLIC_ORIGIN="https://${N8N_PUBLIC_HOSTNAME}"
    ok "Restored public hostnames will be kept unchanged."
    return
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([A-Z0-9_]+_HOSTNAME)=(.*)$ ]] || continue
    variable_name=${BASH_REMATCH[1]}
    raw_value=${BASH_REMATCH[2]}
    current_hostname=$(unquote_env_value "$raw_value")
    current_hostname=${current_hostname,,}

    [[ -n "$current_hostname" ]] || continue
    if ! valid_hostname "$current_hostname"; then
      warn "${variable_name} is not a plain DNS hostname and will not be changed."
      continue
    fi

    if [[ "$current_hostname" == "$old_base_domain" ]]; then
      new_hostname="$new_base_domain"
    elif [[ "$current_hostname" == *".${old_base_domain}" ]]; then
      prefix=${current_hostname%".${old_base_domain}"}
      new_hostname="${prefix}.${new_base_domain}"
    else
      warn "${variable_name} does not use ${old_base_domain} and will not be changed."
      continue
    fi

    hostname_variables+=("$variable_name")
    old_hostnames+=("$current_hostname")
    new_hostnames+=("$new_hostname")
  done < "$env_file"

  (( ${#hostname_variables[@]} > 0 )) || \
    fail "No populated *_HOSTNAME values use ${old_base_domain}."

  printf '\nCalculated hostname changes:\n'
  local index
  for (( index=0; index<${#hostname_variables[@]}; index++ )); do
    printf '  %-28s %s -> %s\n' \
      "${hostname_variables[$index]}" \
      "${old_hostnames[$index]}" \
      "${new_hostnames[$index]}"
  done

  read -r -p "Type DOMAIN to apply these hostname changes: " confirmation
  if [[ "$confirmation" != "DOMAIN" ]]; then
    N8N_PUBLIC_HOSTNAME="$old_n8n_hostname"
    N8N_PUBLIC_ORIGIN="https://${N8N_PUBLIC_HOSTNAME}"
    warn "Domain change was cancelled; restored hostnames were kept."
    return
  fi

  ENV_TEMP_FILE=$(mktemp "${env_file}.domain.XXXXXX")
  chmod --reference="$env_file" "$ENV_TEMP_FILE"

  while IFS= read -r line || [[ -n "$line" ]]; do
    replacement_found="no"
    if [[ "$line" =~ ^([A-Z0-9_]+_HOSTNAME)= ]]; then
      variable_name=${BASH_REMATCH[1]}
      for (( index=0; index<${#hostname_variables[@]}; index++ )); do
        if [[ "$variable_name" == "${hostname_variables[$index]}" ]]; then
          printf '%s=%s\n' "$variable_name" "${new_hostnames[$index]}"
          replacement_found="yes"
          break
        fi
      done
    fi

    [[ "$replacement_found" == "yes" ]] && continue
    printf '%s\n' "$line"
  done < "$env_file" > "$ENV_TEMP_FILE"

  mv -f -- "$ENV_TEMP_FILE" "$env_file"
  ENV_TEMP_FILE=""

  N8N_PUBLIC_HOSTNAME=$(read_env_value N8N_HOSTNAME "$env_file")
  N8N_PUBLIC_HOSTNAME=${N8N_PUBLIC_HOSTNAME,,}
  valid_hostname "$N8N_PUBLIC_HOSTNAME" || \
    fail "N8N_HOSTNAME became invalid after the domain update."
  N8N_PUBLIC_ORIGIN="https://${N8N_PUBLIC_HOSTNAME}"
  ok "Public service hostnames were updated in the restored .env."
}

restore_selfhost_project() {
  step "Restoring the Selfhost AI project"
  cp -a "$RESTORED_SELFHOST" "$SELFHOST_DIR"

  [[ -s "${SELFHOST_DIR}/.env" ]] || fail "Restored .env is missing."
  grep -Eq '^N8N_ENCRYPTION_KEY=.+$' "${SELFHOST_DIR}/.env" || \
    fail "N8N_ENCRYPTION_KEY is missing from restored .env."

  configure_public_domain

  COMPOSE=(
    docker compose
    -f docker-compose.yml
    -f docker-compose.n8n-workers.yml
    -f docker-compose.override.yml
  )

  cd "$SELFHOST_DIR"
  "${COMPOSE[@]}" config >/dev/null

  local resolved_webhook_url
  resolved_webhook_url=$(
    "${COMPOSE[@]}" config |
      awk '
        !found && /^[[:space:]]*WEBHOOK_URL:[[:space:]]*/ {
          sub(/^[[:space:]]*WEBHOOK_URL:[[:space:]]*/, "")
          gsub(/^"|"$/, "")
          value=$0
          found=1
        }
        END {
          if (found) print value
        }
      '
  )
  resolved_webhook_url=${resolved_webhook_url%/}
  [[ "$resolved_webhook_url" == "$N8N_PUBLIC_ORIGIN" ]] || \
    fail "Docker Compose WEBHOOK_URL does not match ${N8N_PUBLIC_ORIGIN}."

  ok "Docker Compose configuration is valid."
  ok "n8n public URL is ${N8N_PUBLIC_ORIGIN}."
}

restore_registry_credentials() {
  local restored_docker_config
  restored_docker_config="${RECOVERY_RUN}/root/.docker/config.json"

  if [[ -f "$restored_docker_config" ]]; then
    step "Restoring encrypted-backup copy of Docker registry credentials"
    install -D -m 600 "$restored_docker_config" /root/.docker/config.json
    ok "Docker registry credentials were restored."
  else
    warn "Docker registry credentials are not present in this snapshot."
    warn "If the n8n image is private, a GHCR token will be requested later."
  fi
}

regenerate_welcome_page() {
  step "Regenerating the Selfhost AI welcome page"
  cd "$SELFHOST_DIR"
  bash scripts/generate_welcome_page.sh
  jq empty welcome/data.json
  ok "Welcome page matches the restored COMPOSE_PROFILES."
}

wait_for_postgres() {
  local status=""

  for _ in $(seq 1 90); do
    status=$(docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      postgres 2>/dev/null || true)

    if [[ "$status" == "healthy" || "$status" == "running" ]]; then
      return 0
    fi

    sleep 2
  done

  return 1
}

restore_postgres() {
  local restore_status
  local started_at
  local elapsed
  local minutes
  local seconds
  local spinner_index=0
  local -a spinner=('|' '/' '-' '\')

  step "Starting a fresh PostgreSQL 17 instance and Redis"
  cd "$SELFHOST_DIR"
  "${COMPOSE[@]}" up -d postgres redis
  wait_for_postgres || fail "PostgreSQL did not become ready within three minutes."

  step "Restoring all PostgreSQL databases and roles"
  POSTGRES_LOG="${RECOVERY_RUN}/postgres-restore.log"

  (
    trap - ERR
    gunzip -c "$RESTORED_DUMP" |
      docker exec -i postgres sh -c \
        'psql -U "$POSTGRES_USER" -d postgres'
  ) > "$POSTGRES_LOG" 2>&1 &
  POSTGRES_RESTORE_PID=$!
  started_at=$SECONDS

  if [[ -t 0 ]]; then
    while kill -0 "$POSTGRES_RESTORE_PID" 2>/dev/null; do
      elapsed=$((SECONDS - started_at))
      minutes=$((elapsed / 60))
      seconds=$((elapsed % 60))
      printf '\r  PostgreSQL restore %s  elapsed %02d:%02d' \
        "${spinner[$spinner_index]}" "$minutes" "$seconds" > /dev/tty
      spinner_index=$(((spinner_index + 1) % ${#spinner[@]}))
      sleep 1
    done
  fi

  if wait "$POSTGRES_RESTORE_PID"; then
    restore_status=0
  else
    restore_status=$?
  fi
  POSTGRES_RESTORE_PID=""

  elapsed=$((SECONDS - started_at))
  minutes=$((elapsed / 60))
  seconds=$((elapsed % 60))
  if [[ -t 0 ]]; then
    printf '\r  PostgreSQL restore finished in %02d:%02d                 \n' \
      "$minutes" "$seconds" > /dev/tty
  fi

  if (( restore_status != 0 )); then
    fail "PostgreSQL restore failed. Detailed log: ${POSTGRES_LOG}"
  fi

  if ! docker exec postgres sh -c \
      'psql -U "$POSTGRES_USER" -d postgres -c "\\l"' \
      >> "$POSTGRES_LOG" 2>&1; then
    fail "PostgreSQL validation failed. Detailed log: ${POSTGRES_LOG}"
  fi

  ok "PostgreSQL restore finished. Log: ${POSTGRES_LOG}"
}

restore_n8n_volume() {
  step "Creating and restoring the n8n persistent volume"
  cd "$SELFHOST_DIR"

  local create_log
  create_log=$(mktemp /run/n8n-recovery-compose.XXXXXX)

  if ! "${COMPOSE[@]}" create n8n 2>&1 | tee "$create_log"; then
    if grep -Eqi 'unauthorized|denied' "$create_log"; then
      warn "The n8n image is private and GHCR authentication is required."

      local ghcr_user
      local ghcr_token
      read -r -p "GitHub username: " ghcr_user
      read -r -s -p "GitHub token with read:packages: " ghcr_token
      printf '\n'

      [[ -n "$ghcr_user" && -n "$ghcr_token" ]] || \
        fail "GitHub username and token are required."

      printf '%s' "$ghcr_token" | \
        docker login ghcr.io -u "$ghcr_user" --password-stdin
      unset ghcr_token

      "${COMPOSE[@]}" create n8n
    else
      rm -f -- "$create_log"
      fail "Docker Compose could not create the n8n container. Review the recovery log."
    fi
  fi

  rm -f -- "$create_log"

  N8N_VOLUME=$(docker inspect n8n \
    --format '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}')

  [[ -n "$N8N_VOLUME" && -d "$N8N_VOLUME" ]] || \
    fail "Could not determine the n8n volume location."

  cp -a "${RESTORED_N8N_DATA}/." "${N8N_VOLUME}/"
  ok "n8n persistent data was restored."
}

container_volume_source() {
  local container=$1
  local destination=$2

  docker inspect "$container" \
    --format "{{range .Mounts}}{{if eq .Destination \"${destination}\"}}{{.Source}}{{end}}{{end}}"
}

restore_support_volumes() {
  step "Creating and restoring Portainer and Caddy volumes"
  cd "$SELFHOST_DIR"
  "${COMPOSE[@]}" create caddy portainer

  PORTAINER_VOLUME=$(container_volume_source portainer /data)
  CADDY_CONFIG_VOLUME=$(container_volume_source caddy /config)
  CADDY_DATA_VOLUME=$(container_volume_source caddy /data)

  [[ -n "$PORTAINER_VOLUME" && -d "$PORTAINER_VOLUME" ]] || \
    fail "Could not determine the Portainer volume location."
  [[ -n "$CADDY_CONFIG_VOLUME" && -d "$CADDY_CONFIG_VOLUME" ]] || \
    fail "Could not determine the Caddy config volume location."
  [[ -n "$CADDY_DATA_VOLUME" && -d "$CADDY_DATA_VOLUME" ]] || \
    fail "Could not determine the Caddy data volume location."

  if [[ -n "$RESTORED_PORTAINER_DATA" ]]; then
    cp -a "${RESTORED_PORTAINER_DATA}/." "${PORTAINER_VOLUME}/"
    ok "Portainer data was restored."
  else
    warn "Portainer volume data is not present in this older snapshot."
  fi

  if [[ -n "$RESTORED_CADDY_CONFIG" ]]; then
    cp -a "${RESTORED_CADDY_CONFIG}/." "${CADDY_CONFIG_VOLUME}/"
    ok "Caddy configuration volume was restored."
  else
    warn "Caddy config volume is not present in this older snapshot."
  fi

  if [[ -n "$RESTORED_CADDY_DATA" ]]; then
    cp -a "${RESTORED_CADDY_DATA}/." "${CADDY_DATA_VOLUME}/"
    ok "Caddy certificate and state data was restored."
  else
    warn "Caddy data volume is not present in this older snapshot."
  fi
}

restored_profile_enabled() {
  local profile=$1
  local profiles
  profiles=$(sed -n 's/^COMPOSE_PROFILES=//p' "${SELFHOST_DIR}/.env")
  [[ ",${profiles}," == *",${profile},"* ]]
}

restore_optional_profile_volume() {
  local container=$1
  local destination=$2
  local restored_source=$3
  local target_volume

  target_volume=$(container_volume_source "$container" "$destination")
  [[ -n "$target_volume" && -d "$target_volume" ]] || \
    fail "Could not determine the ${container} volume location."

  if [[ -n "$restored_source" ]]; then
    cp -a "${restored_source}/." "${target_volume}/"
    ok "${container} persistent data was restored."
  else
    warn "${container} is enabled, but its data is not present in this older snapshot."
  fi
}

restore_standard_optional_profiles() {
  cd "$SELFHOST_DIR"

  if restored_profile_enabled monitoring; then
    step "Restoring the Selfhost AI monitoring profile"
    "${COMPOSE[@]}" create prometheus grafana
    restore_optional_profile_volume \
      grafana /var/lib/grafana "$RESTORED_GRAFANA_DATA"
    restore_optional_profile_volume \
      prometheus /prometheus "$RESTORED_PROMETHEUS_DATA"
  fi

  if restored_profile_enabled databasus; then
    step "Restoring the Selfhost AI Databasus profile"
    "${COMPOSE[@]}" create databasus
    restore_optional_profile_volume \
      databasus /databasus-data "$RESTORED_DATABASUS_DATA"
  fi
}

restore_playwright() {
  step "Restoring Playwright configuration"
  install -d -m 700 "$PLAYWRIGHT_DIR"
  cp -a "${RESTORED_PLAYWRIGHT}/." "${PLAYWRIGHT_DIR}/"

  local n8n_network
  n8n_network=$(docker inspect n8n \
    --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | \
    head -n 1)

  [[ -n "$n8n_network" ]] || \
    fail "Could not determine the restored n8n Docker network."
  docker network inspect "$n8n_network" >/dev/null

  if grep -q 'localai_default' "${PLAYWRIGHT_DIR}/docker-compose.yml"; then
    sed -i "s/localai_default/${n8n_network}/g" \
      "${PLAYWRIGHT_DIR}/docker-compose.yml"
    ok "Playwright Docker network was adapted to ${n8n_network}."
  else
    warn "Playwright configuration does not reference localai_default; no network replacement was made."
  fi

  ok "Playwright configuration was restored to ${PLAYWRIGHT_DIR}."
}

restore_optional_file() {
  local source=$1
  local destination=$2
  local mode=$3

  if [[ -f "$source" ]]; then
    install -D -m "$mode" "$source" "$destination"
    return 0
  fi

  warn "Optional recovery file is missing: $source"
  return 1
}

restore_automation() {
  step "Restoring daily backup automation"

  restore_optional_file \
    "${RECOVERY_RUN}/usr/local/sbin/n8n-daily-backup" \
    "/usr/local/sbin/n8n-daily-backup" \
    700 || true

  if [[ -f /usr/local/sbin/n8n-daily-backup ]]; then
    sed -i \
      -e "s#/var/lib/docker/volumes/localai_n8n_storage/_data#${N8N_VOLUME}#g" \
      -e "s#/var/lib/docker/volumes/selfhost-ai_n8n_storage/_data#${N8N_VOLUME}#g" \
      -e "s#/var/lib/docker/volumes/localai_portainer_data/_data/compose/1#${PLAYWRIGHT_DIR}#g" \
      -e "s#/var/lib/docker/volumes/localai_portainer_data/_data#${PORTAINER_VOLUME}#g" \
      -e "s#/var/lib/docker/volumes/selfhost-ai_portainer_data/_data#${PORTAINER_VOLUME}#g" \
      -e "s#/var/lib/docker/volumes/localai_caddy-config/_data#${CADDY_CONFIG_VOLUME}#g" \
      -e "s#/var/lib/docker/volumes/selfhost-ai_caddy-config/_data#${CADDY_CONFIG_VOLUME}#g" \
      -e "s#/var/lib/docker/volumes/localai_caddy-data/_data#${CADDY_DATA_VOLUME}#g" \
      -e "s#/var/lib/docker/volumes/selfhost-ai_caddy-data/_data#${CADDY_DATA_VOLUME}#g" \
      /usr/local/sbin/n8n-daily-backup

    bash -n /usr/local/sbin/n8n-daily-backup
    ok "Backup paths were adapted to this VPS."
  fi

  restore_optional_file \
    "${RECOVERY_RUN}/etc/systemd/system/n8n-daily-backup.service" \
    "/etc/systemd/system/n8n-daily-backup.service" \
    644 || true

  restore_optional_file \
    "${RECOVERY_RUN}/etc/systemd/system/n8n-daily-backup.timer" \
    "/etc/systemd/system/n8n-daily-backup.timer" \
    644 || true

  install -d -m 700 /root/.ssh

  restore_optional_file \
    "${RECOVERY_RUN}/root/.ssh/config" \
    "/root/.ssh/config" \
    600 || true

  restore_optional_file \
    "${RECOVERY_RUN}/root/.ssh/known_hosts" \
    "/root/.ssh/known_hosts" \
    600 || true

  restore_optional_file \
    "${RECOVERY_RUN}/root/.ssh/n8n_backup_synology_rsa" \
    "/root/.ssh/n8n_backup_synology_rsa" \
    600 || true

  restore_optional_file \
    "${RECOVERY_RUN}/root/.ssh/n8n_backup_synology_rsa.pub" \
    "/root/.ssh/n8n_backup_synology_rsa.pub" \
    644 || true

  systemctl daemon-reload

  SFTP_KEY_OK="no"
  if [[ -f /root/.ssh/config ]] && sftp -b /dev/null homenas-backup; then
    SFTP_KEY_OK="yes"
    ok "Restored key-based SFTP access works."
  else
    warn "Key-based SFTP test failed. The backup timer will remain disabled."
  fi
}

valid_ipv4() {
  local ip=$1
  local octet
  local -a octets

  IFS=. read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

verify_public_endpoint() {
  local target_ip=$1
  local resolved_ips

  step "Checking DNS and HTTPS for ${N8N_PUBLIC_HOSTNAME}"
  resolved_ips=$(
    getent ahostsv4 "$N8N_PUBLIC_HOSTNAME" 2>/dev/null |
      awk '{print $1}' |
      sort -u
  )

  if ! grep -Fxq "$target_ip" <<< "$resolved_ips"; then
    warn "DNS A records for ${N8N_PUBLIC_HOSTNAME} do not point to ${target_ip}."
    return 1
  fi

  if ! curl -fsS \
      --max-time 20 \
      --resolve "${N8N_PUBLIC_HOSTNAME}:443:${target_ip}" \
      "${N8N_PUBLIC_ORIGIN}/healthz" >/dev/null; then
    warn "HTTPS health check failed for ${N8N_PUBLIC_ORIGIN} on ${target_ip}."
    return 1
  fi

  ok "DNS and HTTPS are ready for ${N8N_PUBLIC_ORIGIN}."
}

configure_telegram_webhooks() {
  local trigger_json
  local trigger_count
  local detected_ip=""
  local target_ip
  local confirmation
  local telegram_status=0

  step "Detecting active Telegram Trigger nodes"

  docker exec n8n rm -f -- \
    "$TELEGRAM_WORKFLOWS_FILE" \
    "$TELEGRAM_CREDENTIALS_FILE"

  if ! docker exec n8n n8n export:workflow \
      --all \
      --output="$TELEGRAM_WORKFLOWS_FILE" >/dev/null; then
    warn "Could not inspect restored workflows. Telegram webhook recovery was skipped."
    return 0
  fi

  trigger_json=$(docker exec n8n node -e '
    const fs = require("fs");
    const exported = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const workflows = Array.isArray(exported) ? exported : [exported];
    const triggers = [];

    for (const workflow of workflows.filter((item) => item.active === true)) {
      for (const node of workflow.nodes || []) {
        if (node.type !== "n8n-nodes-base.telegramTrigger") continue;
        triggers.push({
          workflow: workflow.name,
          node: node.name,
          credential: node.credentials?.telegramApi?.name || "unknown credential",
        });
      }
    }

    process.stdout.write(JSON.stringify(triggers));
  ' "$TELEGRAM_WORKFLOWS_FILE")

  trigger_count=$(jq 'length' <<< "$trigger_json")
  if (( trigger_count == 0 )); then
    docker exec n8n rm -f -- "$TELEGRAM_WORKFLOWS_FILE"
    ok "No active Telegram Trigger nodes were found."
    return 0
  fi

  title "Telegram webhook failover"
  printf 'Active Telegram triggers found: %s\n' "$trigger_count"
  jq -r '.[] | "  - \(.workflow) / \(.node) [\(.credential)]"' <<< "$trigger_json"

  detected_ip=$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)
  detected_ip=${detected_ip//[[:space:]]/}
  if ! valid_ipv4 "$detected_ip"; then
    detected_ip=""
  fi

  printf '\n%s\n' \
    "Telegram may retain the old VPS address in its DNS cache." \
    "This step pins restored bot webhooks to the new VPS while preserving n8n secrets." \
    "Before continuing, stop the old VPS and point the n8n DNS record to this VPS."

  if [[ -n "$detected_ip" ]]; then
    read_default target_ip "New VPS public IPv4" "$detected_ip"
  else
    read -r -p "New VPS public IPv4: " target_ip
  fi

  if ! valid_ipv4 "$target_ip"; then
    warn "Invalid IPv4 address. Telegram webhook recovery was skipped."
    docker exec n8n rm -f -- "$TELEGRAM_WORKFLOWS_FILE"
    return 0
  fi

  if ! verify_public_endpoint "$target_ip"; then
    warn "Telegram webhook recovery was skipped until DNS and HTTPS are ready."
    docker exec n8n rm -f -- "$TELEGRAM_WORKFLOWS_FILE"
    return 0
  fi

  read -r -p \
    "Type TELEGRAM to redirect these bot webhooks to ${N8N_PUBLIC_ORIGIN} at ${target_ip}: " \
    confirmation

  if [[ "$confirmation" != "TELEGRAM" ]]; then
    warn "Telegram webhook redirection was skipped."
    docker exec n8n rm -f -- "$TELEGRAM_WORKFLOWS_FILE"
    return 0
  fi

  step "Securely exporting Telegram credentials inside the n8n container"
  if ! docker exec n8n n8n export:credentials \
      --all \
      --decrypted \
      --output="$TELEGRAM_CREDENTIALS_FILE" >/dev/null; then
    warn "Credential export failed. Telegram webhook recovery was skipped."
    docker exec n8n rm -f -- \
      "$TELEGRAM_WORKFLOWS_FILE" \
      "$TELEGRAM_CREDENTIALS_FILE"
    return 0
  fi
  docker exec n8n chmod 600 "$TELEGRAM_CREDENTIALS_FILE"

  step "Redirecting Telegram webhooks to ${N8N_PUBLIC_ORIGIN} at ${target_ip}"
  docker exec -i n8n node - \
    "$target_ip" \
    "$N8N_PUBLIC_HOSTNAME" \
    "$TELEGRAM_WORKFLOWS_FILE" \
    "$TELEGRAM_CREDENTIALS_FILE" <<'NODE' || telegram_status=$?
const fs = require('fs');

const targetIp = process.argv[2];
const targetHostname = process.argv[3];
const workflowExport = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const credentials = JSON.parse(fs.readFileSync(process.argv[5], 'utf8'));
const workflows = Array.isArray(workflowExport) ? workflowExport : [workflowExport];
const activeTriggers = [];

for (const workflow of workflows.filter((item) => item.active === true)) {
  for (const node of workflow.nodes || []) {
    if (node.type === 'n8n-nodes-base.telegramTrigger') {
      activeTriggers.push({ workflow, node });
    }
  }
}

const credentialUse = new Set();
let failures = 0;

async function telegramRequest(baseUrl, token, method, body) {
  const response = await fetch(`${baseUrl}/bot${token}/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
  const data = await response.json();
  if (!data.ok) throw new Error(data.description || `${method} failed`);
  return data.result;
}

(async () => {
  for (const { workflow, node } of activeTriggers) {
    const label = `${workflow.name} / ${node.name}`;

    try {
      const credentialId = node.credentials?.telegramApi?.id;
      const credential = credentials.find(
        (item) => item.type === 'telegramApi' &&
          (!credentialId || String(item.id) === String(credentialId)),
      );

      if (!credential) throw new Error('matching Telegram credential not found');
      if (credentialUse.has(String(credential.id))) {
        throw new Error('the same bot credential is used by more than one active trigger');
      }
      credentialUse.add(String(credential.id));

      const token = credential.data?.accessToken;
      if (!token) throw new Error('Telegram access token is missing');

      const baseUrl = String(
        credential.data?.baseUrl || 'https://api.telegram.org',
      ).replace(/\/$/, '');
      const current = await telegramRequest(baseUrl, token, 'getWebhookInfo', {});
      if (!current.url) throw new Error('Telegram has no active webhook URL');
      const currentUrl = new URL(current.url);
      const targetUrl = new URL(
        `${currentUrl.pathname}${currentUrl.search}`,
        `https://${targetHostname}`,
      ).toString();

      const secretToken = `${workflow.id}_${node.id}`
        .replace(/[^a-zA-Z0-9_-]+/g, '');
      const updates = node.parameters?.updates || [];

      await telegramRequest(baseUrl, token, 'setWebhook', {
        url: targetUrl,
        ip_address: targetIp,
        secret_token: secretToken,
        allowed_updates: updates.includes('*') ? [] : updates,
      });

      const verified = await telegramRequest(baseUrl, token, 'getWebhookInfo', {});
      if (verified.ip_address !== targetIp) {
        throw new Error(`Telegram reports IP ${verified.ip_address || 'unknown'}`);
      }
      if (verified.url !== targetUrl) {
        throw new Error('Telegram reports an unexpected webhook URL');
      }

      console.log(
        `OK: ${label} -> ${verified.ip_address}; pending updates: ` +
        `${verified.pending_update_count || 0}`,
      );
    } catch (error) {
      failures += 1;
      console.error(`ERROR: ${label}: ${error.message}`);
    }
  }

  if (failures > 0) process.exitCode = 1;
})().catch((error) => {
  console.error(`ERROR: Telegram webhook recovery failed: ${error.message}`);
  process.exitCode = 1;
});
NODE

  docker exec n8n rm -f -- \
    "$TELEGRAM_WORKFLOWS_FILE" \
    "$TELEGRAM_CREDENTIALS_FILE"

  if (( telegram_status != 0 )); then
    warn "One or more Telegram webhooks could not be redirected. Review the messages above."
    return 0
  fi

  ok "Telegram webhooks now use ${N8N_PUBLIC_ORIGIN} at the new VPS public IP."
}

show_pre_activation_summary() {
  title "Recovery preparation completed"
  cat <<EOF

Restored and prepared:
  - Selfhost AI project and .env
  - N8N_ENCRYPTION_KEY
  - PostgreSQL databases and roles
  - n8n persistent volume
  - Portainer and Caddy persistent volumes
  - enabled standard Selfhost AI profile data
  - Playwright configuration
  - daily backup automation

Not started yet:
  - n8n main process
  - n8n workers and task runner
  - Playwright
  - backup timer

Before activation:
  1. Confirm the old VPS is stopped or inaccessible.
  2. Confirm duplicate workflows cannot run.
  3. Be ready to change DNS to the new VPS.

Recovery workspace:
  ${RECOVERY_RUN}
EOF
}

activate_services() {
  local activation

  printf '\n'
  read -r -p "Type ACTIVATE to start the restored production system: " activation

  if [[ "$activation" != "ACTIVATE" ]]; then
    warn "Activation skipped. PostgreSQL and Redis remain running; n8n is not running."
    return 0
  fi

  step "Starting the restored Selfhost AI stack"
  cd "$SELFHOST_DIR"
  "${COMPOSE[@]}" up -d

  step "Starting Playwright"
  cd "$PLAYWRIGHT_DIR"
  docker compose \
    --env-file stack.env \
    -p playwright \
    -f docker-compose.yml \
    up -d

  if [[ "$SFTP_KEY_OK" == "yes" && \
        -f /etc/systemd/system/n8n-daily-backup.timer ]]; then
    step "Enabling the daily backup timer"
    systemctl enable --now n8n-daily-backup.timer
  else
    warn "The daily backup timer was not enabled because SFTP key access is not ready."
  fi

  title "Container status"
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

  configure_telegram_webhooks

  title "Manual checks still required"
  cat <<EOF
  1. Point ${N8N_PUBLIC_HOSTNAME} to the new VPS in DNS.
  2. Check Caddy logs and HTTPS.
  3. Open n8n and verify users, credentials and workflows.
  4. Test critical workflows and Playwright MCP.
  5. Disable Tailscale key expiry for the new VPS.
  6. Run and verify a new Restic backup.
  7. Keep the old VPS stopped until all checks pass.
EOF
}

main() {
  require_root

  install -d -m 700 /var/log/n8n-disaster-recovery
  LOG_FILE="/var/log/n8n-disaster-recovery/recovery-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1

  title "n8n Disaster Recovery ${SCRIPT_VERSION}"
  cat <<EOF
This assistant restores an n8n Selfhost AI installation and Playwright
from an encrypted Restic repository stored on Synology.

It is intended only for a fresh Ubuntu VPS.
It will install packages, create Docker containers and restore databases.
It will NOT start n8n workflows without the final ACTIVATE confirmation.

Log file:
  ${LOG_FILE}
EOF

  confirm "Continue on this VPS?" "no" || exit 0

  require_fresh_host
  load_os_release
  install_base_packages
  install_docker
  install_tailscale
  collect_repository_settings
  collect_passwords
  verify_ssh_host_key
  prepare_restic_command
  select_snapshot
  restore_snapshot
  restore_selfhost_project
  regenerate_welcome_page
  restore_registry_credentials
  restore_postgres
  restore_n8n_volume
  restore_support_volumes
  restore_standard_optional_profiles
  restore_playwright
  restore_automation
  show_pre_activation_summary
  activate_services

  title "Recovery script finished"
  printf 'Log file: %s\n' "$LOG_FILE"
}

main "$@"

