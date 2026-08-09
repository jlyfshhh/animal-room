#!/usr/bin/env bash
# Haven: the unified installer and room dashboard for Bask + Shed.
set -Eeuo pipefail

install_root="${ANIMAL_ROOM_HOME:-$HOME}"
dry_run=false
select_bask=false
select_shed=false
select_haven=false
has_selection=false
meminfo_path="${ANIMAL_ROOM_MEMINFO_PATH:-/proc/meminfo}"
health_attempts="${ANIMAL_ROOM_HEALTH_ATTEMPTS:-45}"
health_interval="${ANIMAL_ROOM_HEALTH_INTERVAL:-2}"
bask_installer="${ANIMAL_ROOM_BASK_INSTALLER:-https://raw.githubusercontent.com/jlyfshhh/bask/main/get-bask.sh}"
shed_installer="${ANIMAL_ROOM_SHED_INSTALLER:-https://raw.githubusercontent.com/jlyfshhh/shed/main/get-shed.sh}"
rollback_root=""
rollback_armed=false
health_failure_reason=""

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
die() { printf '\n\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }
warn() { printf '\n\033[1;33mWarning:\033[0m %s\n' "$1" >&2; }

usage() {
  cat <<'USAGE'
Usage: install.sh [--bask] [--shed] [--haven] [--all]
                  [--install-root PATH] [--dry-run]

With no app flags, the installer opens an interactive chooser.

USAGE
}

while (($#)); do
  case "$1" in
    --bask) select_bask=true; has_selection=true ;;
    --shed) select_shed=true; has_selection=true ;;
    --haven)
      select_bask=true
      select_shed=true
      select_haven=true
      has_selection=true
      ;;
    --all)
      select_bask=true
      select_shed=true
      select_haven=true
      has_selection=true
      ;;
    --install-root)
      shift
      (($#)) || die "--install-root needs a path."
      install_root="$1"
      ;;
    --dry-run) dry_run=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

choose_apps() {
  [[ -r /dev/tty ]] || die "No interactive terminal. Use --bask, --shed, or --haven."
  cat >/dev/tty <<'MENU'

  Haven installer
  ---------------
  1) Bask       enclosure climate monitoring
  2) Shed       animal care, schedules, and records
  3) Haven      Bask + Shed + one combined room dashboard (recommended)

  Choose 1, 2, or 3:
MENU
  local answer
  IFS= read -r answer </dev/tty
  answer="${answer//[[:space:]]/}"
  IFS=',' read -r -a choices <<<"$answer"
  local choice
  for choice in "${choices[@]}"; do
    case "$choice" in
      1|bask|Bask) select_bask=true; has_selection=true ;;
      2|shed|Shed) select_shed=true; has_selection=true ;;
      3|haven|Haven|all|All)
        select_bask=true
        select_shed=true
        select_haven=true
        has_selection=true
        ;;
      *) die "Unknown selection: $choice" ;;
    esac
  done
}

[[ "$has_selection" == true ]] || choose_apps

selection=()
[[ "$select_bask" != true ]] || selection+=("bask")
[[ "$select_shed" != true ]] || selection+=("shed")
[[ "$select_haven" != true ]] || selection+=("haven-dashboard")
say "Selected: ${selection[*]}"
echo "    Install root: $install_root"

if [[ "$dry_run" == true ]]; then
  echo "    Dry run: no system or application changes made."
  exit 0
fi

[[ "$health_attempts" =~ ^[1-9][0-9]*$ ]] ||
  die "ANIMAL_ROOM_HEALTH_ATTEMPTS must be a positive whole number."
[[ "$health_interval" =~ ^[0-9]+$ ]] ||
  die "ANIMAL_ROOM_HEALTH_INTERVAL must be a non-negative whole number."

memory_total_mb() {
  [[ -r "$meminfo_path" ]] || return 1
  awk '/^MemTotal:/{printf "%d", $2/1024; found=1} END{exit !found}' "$meminfo_path"
}

# Shed's measured startup peak does not fit on a 512 MB Pi. Check this before
# Docker, downloads, or either app directory is touched. Bask remains supported
# on those boards when selected on its own.
if [[ "$select_shed" == true ]]; then
  if total_memory_mb="$(memory_total_mb)"; then
    if ((total_memory_mb < 900)); then
      die "Shed needs a board with at least 1 GB of RAM (about 900 MB usable); this host reports ${total_memory_mb} MB. Bask can still be installed on its own with --bask."
    fi
  else
    warn "Could not read total memory from $meminfo_path; continuing without the RAM preflight."
  fi
fi

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  die "Run this as your normal user, not with sudo."
fi
command -v sudo >/dev/null 2>&1 || die "sudo is required."

install_docker() {
  say "Installing Docker Engine and Compose"
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  local codename arch
  codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
  arch="$(dpkg --print-architecture)"
  printf '%s\n' \
    "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $codename stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
}

command -v curl >/dev/null 2>&1 || {
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl
}

arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$arch" in
  arm64|aarch64|amd64|x86_64) ;;
  *) die "These containers require a 64-bit OS. Detected architecture: $arch" ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  install_docker
elif ! docker compose version >/dev/null 2>&1; then
  die "Docker is present but the Compose plugin is missing. Install Docker Compose, then rerun."
fi

sudo systemctl enable --now docker >/dev/null 2>&1 || true
sudo usermod -aG docker "$(id -un)" || true

# Group membership granted above does not apply to this shell — it takes effect
# at the next login. So probe what actually works right now and use that for
# everything below. Bare `docker compose` here failed on exactly the install
# this is meant to serve: a fresh machine where the installer had just added
# Docker and the user was not yet in the group.
if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
else
  die "Docker is installed but not reachable. Log out and back in, then run this again."
fi

cleanup_rollback_files() {
  [[ -z "$rollback_root" || ! -d "$rollback_root" ]] || rm -rf "$rollback_root"
}
trap cleanup_rollback_files EXIT

rollback_root="$(mktemp -d "${TMPDIR:-/tmp}/haven-install.XXXXXX")"

snapshot_app() {
  local app="$1" dir="$2" state
  state="$rollback_root/$app"
  mkdir -p "$state"

  local file
  for file in .env compose.yaml; do
    if [[ -f "$dir/$file" ]]; then
      cp -p "$dir/$file" "$state/$file"
      : >"$state/$file.present"
    fi
  done

  if "${DOCKER[@]}" inspect "$app" >/dev/null 2>&1; then
    : >"$state/container.present"
    "${DOCKER[@]}" inspect --format '{{.Image}}' "$app" >"$state/image.id"
    "${DOCKER[@]}" inspect --format '{{.Config.Image}}' "$app" >"$state/image.ref"
    "${DOCKER[@]}" inspect --format '{{.State.Running}}' "$app" >"$state/running"
  fi
}

restore_saved_file() {
  local state="$1" dir="$2" file="$3"
  if [[ -f "$state/$file.present" ]]; then
    mkdir -p "$dir"
    cp -p "$state/$file" "$dir/$file"
  fi
}

rollback_compose() {
  local app="$1" dir="$2"
  shift 2
  if [[ "$app" == bask ]]; then
    (cd "$dir" && env \
      -u BASK_PORT -u BASK_TAG -u BASK_DATA_PATH -u BASK_BIND_ADDRESS \
      -u BASK_UID -u BASK_GID -u BASK_BLUETOOTH_GID \
      -u BASK_WEB_MEMORY_LIMIT -u BASK_SCANNER_MEMORY_LIMIT \
      "${DOCKER[@]}" compose "$@")
  else
    (cd "$dir" && env -u SHED_PORT -u SHED_TAG -u SHED_DATA_PATH "${DOCKER[@]}" compose "$@")
  fi
}

rollback_app() {
  local app="$1" dir="$2" state
  state="$rollback_root/$app"
  [[ -d "$state" ]] || return 0

  if [[ ! -f "$state/container.present" ]]; then
    # There was no prior container. Remove only the failed container/network;
    # bind-mounted data and backups stay on disk, and any prior config returns.
    if [[ -f "$dir/compose.yaml" ]]; then
      rollback_compose "$app" "$dir" down --remove-orphans >/dev/null 2>&1 || true
    fi
    restore_saved_file "$state" "$dir" .env
    restore_saved_file "$state" "$dir" compose.yaml
    return 0
  fi

  restore_saved_file "$state" "$dir" .env
  restore_saved_file "$state" "$dir" compose.yaml

  local image_id image_ref was_running
  image_id="$(<"$state/image.id")"
  image_ref="$(<"$state/image.ref")"
  was_running="$(<"$state/running")"

  # Pulling :latest moves the tag. Point it back at the exact image which was
  # running before the update. Digest references are already immutable.
  if [[ -n "$image_id" && -n "$image_ref" &&
        "$image_ref" != *@sha256:* && "$image_ref" != sha256:* ]]; then
    "${DOCKER[@]}" image tag "$image_id" "$image_ref" >/dev/null 2>&1 || return 1
  fi
  [[ -f "$dir/compose.yaml" ]] || return 1
  rollback_compose "$app" "$dir" up -d --no-build --pull never >/dev/null 2>&1 || return 1
  if [[ "$was_running" != true ]]; then
    rollback_compose "$app" "$dir" stop >/dev/null 2>&1 || return 1
  fi
}

rollback_all() {
  local failed=false index app dir
  say "Restoring the previous running configuration"
  for ((index=${#selection[@]} - 1; index >= 0; index--)); do
    app="${selection[$index]}"
    [[ "$app" != haven-dashboard ]] || continue
    dir="$install_root/$app"
    if ! rollback_app "$app" "$dir"; then
      warn "Could not completely restore $app automatically. Its records were not removed."
      failed=true
    fi
  done
  [[ "$failed" == false ]]
}

handle_unexpected_error() {
  local line="$1" status="$2"
  trap - ERR
  if [[ "$rollback_armed" == true ]]; then
    rollback_all || true
    printf '\n\033[1;31mError:\033[0m Installation failed near line %s; the previous services were restored. No application data was removed.\n' "$line" >&2
  fi
  exit "$status"
}
trap 'handle_unexpected_error "$LINENO" "$?"' ERR

fail_with_rollback() {
  local message="$1"
  trap - ERR
  rollback_all || true
  rollback_armed=false
  die "$message The previous services were restored, and no application data was removed."
}

[[ "$select_bask" != true ]] || snapshot_app bask "$install_root/bask"
[[ "$select_shed" != true ]] || snapshot_app shed "$install_root/shed"
rollback_armed=true

run_remote_installer() {
  local app="$1" source="$2" variable="$3" destination="$4"
  say "Installing $app"
  if [[ -f "$source" ]]; then
    bash -n "$source"
    env "$variable=$destination" bash "$source"
    return
  fi

  # Finish the download and syntax-check it before executing anything. This
  # avoids the partial-script behavior of curl | bash on a dropped connection.
  local app_slug downloaded
  app_slug="$(printf '%s' "$app" | tr '[:upper:]' '[:lower:]')"
  downloaded="$rollback_root/${app_slug}-installer.sh"
  curl -fsSL "$source" -o "$downloaded"
  bash -n "$downloaded"
  env "$variable=$destination" bash "$downloaded"
}

if [[ "$select_bask" == true ]]; then
  if ! run_remote_installer \
    "Bask" \
    "$bask_installer" \
    "BASK_INSTALL_DIR" \
    "$install_root/bask"; then
    fail_with_rollback "Bask's installer did not finish."
  fi
fi
if [[ "$select_shed" == true ]]; then
  if ! run_remote_installer \
    "Shed" \
    "$shed_installer" \
    "SHED_INSTALL_DIR" \
    "$install_root/shed"; then
    fail_with_rollback "Shed's installer did not finish."
  fi
fi

set_env_value() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file"
    rm -f "${file}.bak"
  else
    printf '\n%s=%s\n' "$key" "$value" >>"$file"
  fi
}

get_env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1 | tr -d '\r'
}

resolve_port() {
  local file="$1" key="$2" default="$3" value
  value="$(printenv "$key" 2>/dev/null || true)"
  [[ -n "$value" ]] || value="$(get_env_value "$file" "$key")"
  value="${value:-$default}"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value < 1 || value > 65535)); then
    fail_with_rollback "$key must be a port from 1 through 65535; found '$value'."
  fi
  printf '%s' "$value"
}

bask_env="$install_root/bask/.env"
shed_env="$install_root/shed/.env"
bask_port=8080
shed_port=3000
if [[ "$select_bask" == true ]]; then
  [[ -f "$bask_env" ]] || fail_with_rollback "Bask settings were not created at $bask_env."
  bask_port="$(resolve_port "$bask_env" BASK_PORT 8080)"
  # An explicit environment override must survive a reboot, not only this
  # invocation of Compose.
  [[ -z "${BASK_PORT:-}" ]] || set_env_value "$bask_env" BASK_PORT "$bask_port"
fi
if [[ "$select_shed" == true ]]; then
  [[ -f "$shed_env" ]] || fail_with_rollback "Shed settings were not created at $shed_env."
  shed_port="$(resolve_port "$shed_env" SHED_PORT 3000)"
  [[ -z "${SHED_PORT:-}" ]] || set_env_value "$shed_env" SHED_PORT "$shed_port"
fi

if [[ "$select_haven" == true ]]; then
  say "Connecting Bask and Shed for the Haven room dashboard"
  display_token="$(get_env_value "$shed_env" SHED_DISPLAY_TOKEN)"
  if [[ -z "$display_token" || "$display_token" == replace-with-* ]]; then
    display_token="$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    set_env_value "$shed_env" "SHED_DISPLAY_TOKEN" "$display_token"
    if ! (cd "$install_root/shed" && "${DOCKER[@]}" compose up -d); then
      fail_with_rollback "Shed could not restart with its Haven display token."
    fi
  fi

  # Both containers run on the same host. Bask reads this feed server-side, so
  # the display secret is never exposed to the dashboard browser.
  set_env_value "$bask_env" "SHED_DISPLAY_URL" "http://host.docker.internal:${shed_port}/api/display"
  set_env_value "$bask_env" "SHED_DISPLAY_TOKEN" "$display_token"
  if ! (cd "$install_root/bask" && "${DOCKER[@]}" compose pull -q && "${DOCKER[@]}" compose up -d); then
    fail_with_rollback "Bask could not restart with its Haven connection."
  fi
fi

container_value() {
  local app="$1" format="$2"
  "${DOCKER[@]}" inspect --format "$format" "$app" 2>/dev/null || true
}

wait_for_app() {
  local app="$1" port="$2" attempt code running oom health_state
  local scanner_running="" scanner_oom=""
  health_failure_reason="$app did not answer its health endpoint on port $port"
  for ((attempt=1; attempt<=health_attempts; attempt++)); do
    oom="$(container_value "$app" '{{.State.OOMKilled}}')"
    if [[ "$oom" == true ]]; then
      health_failure_reason="$app was killed because the host ran out of memory"
      return 1
    fi

    running="$(container_value "$app" '{{.State.Running}}')"
    health_state="$(container_value "$app" '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
    if [[ "$app" == bask ]]; then
      scanner_oom="$(container_value bask-scanner '{{.State.OOMKilled}}')"
      scanner_running="$(container_value bask-scanner '{{.State.Running}}')"
      if [[ "$scanner_oom" == true ]]; then
        health_failure_reason="Bask's Bluetooth scanner was killed because the host ran out of memory"
        return 1
      fi
    fi
    code="$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:${port}/api/health" 2>/dev/null || true)"
    if [[ "$running" == true && "$code" == 200 &&
          ( "$app" != bask || "$scanner_running" == true ) ]]; then
      return 0
    fi
    if [[ "$app" == bask && -z "$scanner_running" ]]; then
      health_failure_reason="Bask's Bluetooth scanner container was not created"
    elif [[ "$app" == bask && "$scanner_running" != true ]]; then
      health_failure_reason="Bask's Bluetooth scanner stopped during startup"
    elif [[ "$health_state" == unhealthy ]]; then
      health_failure_reason="$app's container health check reported unhealthy"
    elif [[ -z "$running" ]]; then
      health_failure_reason="$app's container was not created"
    elif [[ "$running" != true ]]; then
      health_failure_reason="$app's container stopped during startup"
    fi
    ((attempt == health_attempts)) || sleep "$health_interval"
  done
  return 1
}

dashboard_reports_shed_available() {
  local payload="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; data=json.load(sys.stdin); raise SystemExit(0 if data.get("shed", {}).get("available") is True else 1)' <<<"$payload" 2>/dev/null
  else
    grep -Eq '"shed"[[:space:]]*:[[:space:]]*\{[^}]*"available"[[:space:]]*:[[:space:]]*true' <<<"$payload"
  fi
}

wait_for_haven_bridge() {
  local attempt payload
  health_failure_reason="Bask could not confirm its read-only connection to Shed"
  for ((attempt=1; attempt<=health_attempts; attempt++)); do
    payload="$(curl -fsS -m 5 "http://127.0.0.1:${bask_port}/api/room-dashboard" 2>/dev/null || true)"
    if [[ -n "$payload" ]] && dashboard_reports_shed_available "$payload"; then
      return 0
    fi
    ((attempt == health_attempts)) || sleep "$health_interval"
  done
  return 1
}

say "Verifying the selected services"
if [[ "$select_shed" == true ]] && ! wait_for_app shed "$shed_port"; then
  fail_with_rollback "$health_failure_reason."
fi
if [[ "$select_bask" == true ]] && ! wait_for_app bask "$bask_port"; then
  fail_with_rollback "$health_failure_reason."
fi
if [[ "$select_haven" == true ]] && ! wait_for_haven_bridge; then
  fail_with_rollback "$health_failure_reason."
fi

rollback_armed=false

host="$(hostname)"
# A .local name needs mDNS, which Windows without Bonjour and a good number of
# Android phones do not do — the address simply refuses to load, with nothing to
# say why. The LAN address always works, so lead with it and offer the friendly
# name second.
lan_ip="$(
  ip -4 -o addr show scope global 2>/dev/null |
    awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap)/ {print $4}' |
    cut -d/ -f1 |
    grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' |
    head -n 1 || true
)"
address() {
  local port="$1" path="${2:-}"
  if [[ -n "$lan_ip" ]]; then
    printf 'http://%s:%s%s\n' "$lan_ip" "$port" "$path"
    printf '                    or http://%s.local:%s%s\n' "$host" "$port" "$path"
  else
    printf 'http://%s.local:%s%s\n' "$host" "$port" "$path"
  fi
}
cat <<SUMMARY

Installation complete.

Open these from any phone or computer on the same network:

$( [[ "$select_bask" != true ]] || printf '  Bask:    %s' "$(address "$bask_port")" )
$( [[ "$select_shed" != true ]] || printf '  Shed:    %s' "$(address "$shed_port")" )
$( [[ "$select_haven" != true ]] || printf '  Haven:   %s' "$(address "$bask_port" /room.html)" )

Each app keeps its own database and settings in its data directory.
Run this same installer again to update the selected apps without replacing data.

If an address will not load, run this and send us what it prints:
  curl -fsSL https://animalroom.app/doctor.sh | bash
SUMMARY
