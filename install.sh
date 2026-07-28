#!/usr/bin/env bash
# Unified installer for Bask, Shed, and Clarity.
set -euo pipefail

install_root="${ANIMAL_ROOM_HOME:-$HOME}"
dry_run=false
select_bask=false
select_shed=false
select_clarity=false
has_selection=false

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
die() { printf '\n\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: install.sh [--bask] [--shed] [--clarity] [--all]
                  [--install-root PATH] [--dry-run]

With no app flags, the installer opens an interactive chooser.
USAGE
}

while (($#)); do
  case "$1" in
    --bask) select_bask=true; has_selection=true ;;
    --shed) select_shed=true; has_selection=true ;;
    --clarity) select_clarity=true; has_selection=true ;;
    --all)
      select_bask=true
      select_shed=true
      select_clarity=true
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
  [[ -r /dev/tty ]] || die "No interactive terminal. Use --bask, --shed, --clarity, or --all."
  cat >/dev/tty <<'MENU'

  Animal Room installer
  ---------------------
  1) Bask       enclosure sensor monitoring
  2) Shed       terrestrial animal husbandry
  3) Clarity    aquarium and pond care
  4) All three

  Choose one, several (example: 1,2), or 4:
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
      3|clarity|Clarity) select_clarity=true; has_selection=true ;;
      4|all|All)
        select_bask=true
        select_shed=true
        select_clarity=true
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
[[ "$select_clarity" != true ]] || selection+=("clarity")
say "Selected: ${selection[*]}"
echo "    Install root: $install_root"

if [[ "$dry_run" == true ]]; then
  echo "    Dry run: no system or application changes made."
  exit 0
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

run_remote_installer() {
  local app="$1" url="$2" variable="$3" destination="$4"
  say "Installing $app"
  curl -fsSL "$url" | env "$variable=$destination" bash
}

if [[ "$select_bask" == true ]]; then
  run_remote_installer \
    "Bask" \
    "https://raw.githubusercontent.com/jlyfshhh/bask/main/get-bask.sh" \
    "BASK_INSTALL_DIR" \
    "$install_root/bask"
fi
if [[ "$select_shed" == true ]]; then
  run_remote_installer \
    "Shed" \
    "https://raw.githubusercontent.com/jlyfshhh/shed/main/get-shed.sh" \
    "SHED_INSTALL_DIR" \
    "$install_root/shed"
fi
if [[ "$select_clarity" == true ]]; then
  run_remote_installer \
    "Clarity" \
    "https://raw.githubusercontent.com/jlyfshhh/clarity/main/get-clarity.sh" \
    "CLARITY_INSTALL_DIR" \
    "$install_root/clarity"
fi

host="$(hostname)"
cat <<SUMMARY

Installation complete.

$( [[ "$select_bask" != true ]] || printf '  Bask:    http://%s.local:8080\n' "$host" )
$( [[ "$select_shed" != true ]] || printf '  Shed:    http://%s.local:3000\n' "$host" )
$( [[ "$select_clarity" != true ]] || printf '  Clarity: http://%s.local:3001\n' "$host" )

Each app keeps its own database and settings in its data directory.
Run this same installer again to update the selected apps without replacing data.
SUMMARY
