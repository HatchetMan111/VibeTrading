#!/usr/bin/env bash
# =============================================================================
# Vibe-Trading — Proxmox LXC Installer (Community-Scripts-Stil)
#
# Einzeiler (auf dem Proxmox-HOST als root ausführen):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VibeTrading/main/install/vibe-trading.sh)"
#
# Was passiert:
#   1. Fragt CT-ID, Hostname, CPU/RAM/Disk, Storage, Netzwerk, Web-Port ab
#   2. Erstellt einen Debian-12-LXC (onboot=1), startet ihn
#   3. Schiebt Wrapper-Dateien (systemd/, setup) in den Container
#   4. Installiert dort Vibe-Trading (Upstream-Clone + venv + Frontend-Build)
#      als systemd-Service (Web UI = native Vibe-Trading UI, alles einstellbar)
#   5. Verifiziert Service + HTTP und gibt die finale URL aus
#
# Kollisionssicher: ist die CT-ID belegt, wird automatisch die nächste freie genommen.
# Debugging:  DEBUG=1 bash -x install/vibe-trading.sh   (volles Trace-Log)
# =============================================================================
set -euo pipefail

# ============================ VARIABLEN (oben) ================================
APP="vibe-trading"
GITHUB_USER="${GITHUB_USER:-HatchetMan111}"
GITHUB_REPO="${GITHUB_REPO:-VibeTrading}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"
TARBALL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"

DEFAULT_CTID="${DEFAULT_CTID:-152}"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-vibe-trading}"
DEFAULT_CORES="${DEFAULT_CORES:-4}"
DEFAULT_MEMORY="${DEFAULT_MEMORY:-4096}"     # MB (Build braucht RAM: Node 22 + pip-Locks)
DEFAULT_DISK="${DEFAULT_DISK:-20}"           # GB (Upstream + venv + frontend/dist + Runs)
DEFAULT_STORAGE="${DEFAULT_STORAGE:-local-lvm}"
DEFAULT_TEMPLATE_STORAGE="${DEFAULT_TEMPLATE_STORAGE:-local}"
DEFAULT_BRIDGE="${DEFAULT_BRIDGE:-vmbr0}"
DEFAULT_WEB_PORT="${DEFAULT_WEB_PORT:-8899}"
DEBIAN_TEMPLATE_PATTERN="debian-12-standard.*amd64.tar.zst"

# ========================= FEHLERKETTE (voll, nie 1 Zeile) =====================
fail() {
  local code=$?
  echo "==================================================================" >&2
  echo "[FATAL] Installation fehlgeschlagen (Exit-Code: ${code})" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Zeile  : ${BASH_LINENO[0]:-?}" >&2
  echo "--- Funktions-Stack ---" >&2
  local i
  for ((i=0; i<${#FUNCNAME[@]}; i++)); do
    echo "  #${i} ${FUNCNAME[$i]:-main} @ ${BASH_SOURCE[$i]}:${BASH_LINENO[$i]:-?}" >&2
  done
  echo "--- Letzte pct-Auszüge (falls vorhanden) ---" >&2
  pct status "${CTID:-?}" 2>&1 | tail -n 20 >&2 || true
  echo "Tipp: Re-Run mit Trace: DEBUG=1 bash -x $0" >&2
  echo "==================================================================" >&2
  exit "${code}"
}
trap fail ERR
[[ "${DEBUG:-0}" == "1" ]] && set -x

# ================================ CHECKS ======================================
[[ "$(id -u)" == "0" ]] || { echo "Bitte als root auf dem Proxmox-Host ausführen." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct nicht gefunden — kein Proxmox-Host?" >&2; exit 1; }
command -v pveam >/dev/null || { echo "pveam nicht gefunden — kein Proxmox-Host?" >&2; exit 1; }

ask() { # ask VAR "Prompt" "Default"
  local __var=$1 prompt=$2 def=$3 val
  if command -v whiptail >/dev/null; then
    val=$(whiptail --inputbox "${prompt}" 8 70 "${def}" 3>&1 1>&2 2>&3) || val="${def}"
  else
    read -rp "${prompt} [${def}]: " val; val="${val:-$def}"
  fi
  printf -v "${__var}" '%s' "${val}"
}

echo "=== ${APP} LXC-Installer (Proxmox VE Community-Scripts-Stil) ==="
echo "Upstream: https://github.com/HKUDS/Vibe-Trading (Web UI nativ enthalten)"
ask CTID        "Container-ID (CT-ID)"               "${DEFAULT_CTID}"
ask HOSTNAME    "Hostname"                           "${DEFAULT_HOSTNAME}"
ask CORES       "vCPU-Kerne (Build braucht CPU)"     "${DEFAULT_CORES}"
ask MEMORY      "RAM in MB (min. 4096 empfohlen)"    "${DEFAULT_MEMORY}"
ask DISK        "Disk in GB (min. 20 empfohlen)"     "${DEFAULT_DISK}"
ask STORAGE     "Storage für Disk (z. B. local-lvm)" "${DEFAULT_STORAGE}"
ask TPL_STORAGE "Storage für Templates"              "${DEFAULT_TEMPLATE_STORAGE}"
ask BRIDGE      "Netzwerk-Bridge"                    "${DEFAULT_BRIDGE}"
ask WEB_PORT    "Web-UI-Port"                        "${DEFAULT_WEB_PORT}"

# --- CT-ID belegt? -> automatisch nächste freie nehmen ---------------------------
[[ "${CTID}" =~ ^[0-9]+$ ]] || { echo "CT-ID muss numerisch sein (bekommen: '${CTID}')." >&2; exit 1; }
TRIES=0
while pct status "${CTID}" >/dev/null 2>&1; do
  echo "-> CT ${CTID} ist belegt, nehme nächste freie ..."
  CTID=$((CTID + 1))
  TRIES=$((TRIES + 1))
  if (( CTID > 999999999 )); then echo "Keine freie CT-ID mehr (Limit 999999999 erreicht)." >&2; exit 1; fi
  if (( TRIES > 500 )); then echo "Nach 500 Versuchen keine freie CT-ID gefunden." >&2; exit 1; fi
done
echo "-> Verwende CT-ID ${CTID}."

# --- Template sicherstellen ----------------------------------------------------
echo "-> Suche Debian-12-Template in ${TPL_STORAGE} ..."
TEMPLATE="$(pveam list "${TPL_STORAGE}" 2>/dev/null | grep -oE "${DEBIAN_TEMPLATE_PATTERN}" | sort -V | tail -n 1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  echo "-> Kein Template gefunden, lade aktuelles (pveam update + download) ..."
  pveam update
  TEMPLATE="$(pveam available 2>/dev/null | grep -oE "${DEBIAN_TEMPLATE_PATTERN}" | sort -V | tail -n 1)"
  [[ -n "${TEMPLATE}" ]] || { echo "Kein Debian-12-Template verfügbar." >&2; exit 1; }
  pveam download "${TPL_STORAGE}" "${TEMPLATE}"
fi
echo "-> Template: ${TEMPLATE}"

# --- Container erstellen ---------------------------------------------------------
echo "-> Erstelle LXC ${CTID} (${CORES} CPU / ${MEMORY} MB / ${DISK} GB) ..."
pct create "${CTID}" "${TPL_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" --memory "${MEMORY}" \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --onboot 1 --start 1 \
  --unprivileged 1 \
  --features nesting=1
# onboot doppelt absichern (Config-Key)
grep -q "^onboot:" "/etc/pve/lxc/${CTID}.conf" \
  || echo "onboot: 1" >> "/etc/pve/lxc/${CTID}.conf"
echo "-> Warte auf Container-Boot ..."
sleep 8

pct exec "${CTID}" -- bash -c "echo Container erreichbar: \$(hostname) \$(hostname -I | awk '{print \$1}')"

# --- Wrapper-Dateien in den Container schieben ----------------------------------
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap 'cleanup; fail' ERR
echo "-> Lade Wrapper-Repo (${GITHUB_USER}/${GITHUB_REPO}@${GITHUB_BRANCH}) ..."
if command -v git >/dev/null; then
  git clone --depth 1 --branch "${GITHUB_BRANCH}" \
    "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" "${WORKDIR}/repo"
else
  cd "${WORKDIR}" && wget -qO repo.tar.gz "${TARBALL}" && tar xzf repo.tar.gz
  mv "${WORKDIR}/${GITHUB_REPO}-${GITHUB_BRANCH}" "${WORKDIR}/repo"
fi

echo "-> Push nach CT:${CTID} ..."
pct exec "${CTID}" -- mkdir -p /opt/vibe-trading/repo-files/systemd
pct push "${CTID}" "${WORKDIR}/repo/systemd/vibe-trading.service" \
  /opt/vibe-trading/repo-files/systemd/vibe-trading.service
pct push "${CTID}" "${WORKDIR}/repo/install/setup-container.sh" \
  /opt/vibe-trading/setup-container.sh
if [[ -f "${WORKDIR}/repo/.env.example" ]]; then
  pct push "${CTID}" "${WORKDIR}/repo/.env.example" \
    /opt/vibe-trading/repo-files/.env.example
fi
pct exec "${CTID}" -- chmod +x /opt/vibe-trading/setup-container.sh

# --- Setup IM Container ausführen ------------------------------------------------
echo "-> Führe Setup im Container aus (dauert 10–20 Minuten: pip-Locks + Frontend-Build) ..."
pct exec "${CTID}" -- env WEB_PORT="${WEB_PORT}" DEBUG="${DEBUG:-0}" \
  bash /opt/vibe-trading/setup-container.sh

# --- Verifikation vom Host -------------------------------------------------------
echo "-> Verifikation ..."
pct exec "${CTID}" -- systemctl is-active --quiet vibe-trading \
  || { echo "Service läuft NICHT. Log:" >&2
       pct exec "${CTID}" -- journalctl -u vibe-trading --no-pager -n 100 >&2
       exit 1; }
CT_IP="$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')"
echo "-> HTTP-Check http://${CT_IP}:${WEB_PORT}/live ..."
curl -fsS "http://${CT_IP}:${WEB_PORT}/live" || {
  echo "HTTP-Check fehlgeschlagen." >&2
  pct exec "${CTID}" -- journalctl -u vibe-trading --no-pager -n 100 >&2
  exit 1
}
cleanup
trap fail ERR

echo "=================================================================="
echo " ✅ Fertig! Vibe-Trading Web UI: http://${CT_IP}:${WEB_PORT}"
echo "    CT-ID ${CTID} (${HOSTNAME}), onboot=1, Service=vibe-trading"
echo "    Alles einstellbar in der Web UI (Provider, Modelle, Keys, Research,"
echo "    Backtests, Scheduled, Settings) — siehe README."
echo "    Update im Container: pct exec ${CTID} -- bash /opt/vibe-trading/setup-container.sh"
echo "    Neuer Container      : Einzeiler erneut (nächste freie CT-ID wird auto-gewählt)"
echo "    Logs   : pct exec ${CTID} -- journalctl -u vibe-trading -f"
echo "    Löschen: pct stop ${CTID} && pct destroy ${CTID}"
echo "=================================================================="
