<p align="center">
  <b>🌿 Haven</b><br>
  One installer for <b>Bask</b>, <b>Shed</b>, or their combined animal-room dashboard.
</p>

<p align="center">
  <a href="#install"><img alt="One-line install" src="https://img.shields.io/badge/install-one%20command-success"></a>
  <a href="https://jlyfshhh.github.io/animal-room/"><img alt="Haven website" src="https://img.shields.io/badge/website-meet%20Haven-3f755a"></a>
  <img alt="Raspberry Pi" src="https://img.shields.io/badge/Raspberry%20Pi-64--bit-C51A4A?logo=raspberrypi&logoColor=white">
  <a href="https://ko-fi.com/jlyfshhh"><img alt="Ko-fi" src="https://img.shields.io/badge/Ko--fi-buy%20crickets-FF5E5B?logo=ko-fi&logoColor=white"></a>
</p>

---

**Bask watches the habitat. Shed organizes the care. Haven brings both into
one calm room dashboard.**

Haven is not another database or another app to maintain. It is the combined
installation and read-only wall display you get when Bask and Shed run
together. Each app stays independent, and each keeps its own portable data.

**[Meet Haven on the project website →](https://jlyfshhh.github.io/animal-room/)**

## Which should I choose?

| Choice | Best when you want |
|---|---|
| **Bask** | Live enclosure temperature and humidity monitoring from compatible Bluetooth sensors |
| **Shed** | Shared care schedules, household task attribution, weights, feeding, equipment, notes, and history |
| **Haven** *(recommended)* | Everything in Bask and Shed, plus one wall dashboard showing enclosure status and today's remaining care |

You can start with either app and run the installer again later to add the
other one and enable Haven. No data is replaced.

## Install

On a 64-bit Raspberry Pi running Raspberry Pi OS, or another 64-bit Debian
system, run:

```bash
curl -fsSL https://raw.githubusercontent.com/jlyfshhh/animal-room/main/install.sh | bash
```

Choose **Bask**, **Shed**, or **Haven**. The installer adds Docker from Docker's
official Debian repository when needed, installs the selected app or apps, and
automatically makes the secure server-to-server connection required by Haven.

For an unattended Haven install:

```bash
curl -fsSL https://raw.githubusercontent.com/jlyfshhh/animal-room/main/install.sh |
  bash -s -- --haven
```

`--bask`, `--shed`, and `--all` are also accepted. `--all` is an alias for
Haven. Re-running the command updates the selected apps without replacing data.

## Addresses and storage

| Surface | Address | Persistent data |
|---|---|---|
| Bask | `http://HOSTNAME.local:8080` | `~/bask/data` |
| Shed | `http://HOSTNAME.local:3000` | `~/shed/data` |
| Haven room display | `http://HOSTNAME.local:8080/room.html` | Reads Bask and Shed; stores no separate copy |

Set `ANIMAL_ROOM_HOME` or pass `--install-root PATH` to choose a different
parent directory.

## What Haven shares

Haven gives Bask read-only access to a deliberately limited Shed display feed.
That feed includes today's incomplete and overdue care plus anonymous totals.
It excludes household identities, rewards, access codes, history, completion
IDs, and all write access. A separate random display secret is generated during
installation and stays in the apps' private `.env` files; it is never sent to
the browser.

Because Bask and Shed remain separate services, either app can still be used on
its own. The room display clearly reports when one side is unavailable instead
of hiding the failure.

## Existing Bask or Shed installs

Run the Haven installer with the same install root. Existing databases,
settings, and backups remain in place. Bask also safely migrates its former
systemd/virtualenv installation when it detects one, including a timestamped
pre-migration SQLite snapshot.

## Data ownership and safety

- Bask and Shed keep ordinary files in separate `data` directories.
- Both projects include backup tools; Shed also exports portable JSON and CSV.
- The installer does not merge databases or upload animal data to a cloud.
- Do not expose ports 8080 or 3000 directly to the public internet.

Clarity, the earlier aquatic companion, is archived. Existing Clarity installs
continue to work, and the legacy `--clarity` installer flag remains available
for current users, but it is no longer part of the new-user chooser.

## Projects

| | Project | Purpose |
|---|---|---|
| ☀️ | **[Bask](https://github.com/jlyfshhh/bask)** | The environment — live enclosure temperature and humidity |
| 🐍 | **[Shed](https://github.com/jlyfshhh/shed)** | The care — schedules, records, weights, feeding, and shared household work |
| 🌿 | **Haven** *(this repo)* | The bridge — one installer and one room view for Bask + Shed |
