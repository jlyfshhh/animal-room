#!/usr/bin/env bash
# animalroom.app/shed/install.sh
#
# A pointer to Shed's own installer, so every install command on the site has
# the same shape. This deliberately does NOT use the Haven installer: that one
# installs Docker through apt and so only runs on Debian, while get-shed.sh
# needs nothing but Docker already present and works on a NAS, Fedora, or
# anything else.
set -euo pipefail

url="https://raw.githubusercontent.com/jlyfshhh/shed/main/get-shed.sh"
installer="$(curl -fsSL "$url")" || {
  echo "Could not download the Shed installer from $url" >&2
  exit 1
}
# A truncated or empty download must fail loudly rather than quietly doing nothing.
[ -n "$installer" ] || { echo "The Shed installer downloaded empty. Try again." >&2; exit 1; }

exec bash -c "$installer"
