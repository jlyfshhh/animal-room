#!/usr/bin/env bash
# animalroom.app/bask/install.sh
#
# A pointer to Bask's own installer, so every install command on the site has
# the same shape. This deliberately does NOT use the Haven installer: that one
# installs Docker through apt and so only runs on Debian, while get-bask.sh
# needs nothing but Docker already present and works on a NAS, Fedora, or
# anything else.
set -euo pipefail

url="https://raw.githubusercontent.com/jlyfshhh/bask/main/get-bask.sh"
installer="$(curl -fsSL "$url")" || {
  echo "Could not download the Bask installer from $url" >&2
  exit 1
}
# A truncated or empty download must fail loudly rather than quietly doing nothing.
[ -n "$installer" ] || { echo "The Bask installer downloaded empty. Try again." >&2; exit 1; }

exec bash -c "$installer"
