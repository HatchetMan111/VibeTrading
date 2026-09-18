#!/usr/bin/env bash
# =============================================================================
# Vibe-Trading — Container-Setup (läuft IM LXC, Debian 12, als root)
# Wird vom Host-Installer per pct push + pct exec aufgerufen oder manuell:
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/VibeTrading/main/install/setup-container.sh | bash
# Idempotent: kann mehrfach laufen (Upstream pull, venv wiederverwenden,
# Frontend-Build nur bei Bedarf neu, Service restart).
# Debugging: DEBUG=1 bash -x setup-container.sh  -> volles Trace-Log
# =============================================================================
set -euo pipefail

# --- Variablen (oben, Community-Scripts-Stil) ---------------------------------
APP="vibe-trading"
BASE_DIR="/opt/vibe-trading"
UPSTREAM_DIR="${BASE_DIR}/upstream"
UPSTREAM_REPO="https://github.com/HKUDS/Vibe-Trading.git"
UPSTREAM_BRANCH="main"
VENV_DIR="${BASE_DIR}/venv"
WEB_PORT="${WEB_PORT:-8899}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SERVICE_NAME="vibe-trading"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="${UPSTREAM_DIR}/agent/.env"

# --- Fehlerkette: immer VOLL ausgeben, nie nur letzte Zeile -------------------
fail() {
  local code=$?
  echo "==================================================================" >&2
  echo "[FATAL] Setup fehlgeschlagen (Exit-Code: ${code})" >&2
  echo "--- Befehl / Kontext ---" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Zeile  : ${BASH_LINENO[0]:-?} in ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" >&2
  echo "--- Stacktrace ---" >&2
  local i
  for ((i=0; i<${#FUNCNAME[@]}; i++)); do
    echo "  #${i} ${FUNCNAME[$i]:-main} @ ${BASH_SOURCE[$i]}:${BASH_LINENO[$i]:-?}" >&2
  done
  echo "--- Relevante Logs ---" >&2
  journalctl -u "${SERVICE_NAME}" --no-pager -n 50 2>&1 | tail -n 50 >&2 || true
  echo "Tipp: Re-Run mit Debug-Trace: DEBUG=1 bash -x $0" >&2
  echo "==================================================================" >&2
  exit "${code}"
}
trap fail ERR

if [[ "${DEBUG:-0}" == "1" ]]; then set -x; fi

echo "[1/8] Systempakete (Python 3.11, Node 22, Build-Tools, WeasyPrint-Libs) ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  "${PYTHON_BIN}" "${PYTHON_BIN}-venv" "${PYTHON_BIN}-dev" \
  git curl ca-certificates build-essential \
  libpango-1.0-0 libpangoft2-1.0-0 libharfbuzz0b libfontconfig1 \
  libgdk-pixbuf-2.0-0 libcairo2 fonts-dejavu-core

# --- Node 22 sicherstellen (Upstream engines: node >= 22.22) -------------------
NEED_NODE=0
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [[ "${NODE_MAJOR}" -lt 22 ]]; then NEED_NODE=1; fi
else
  NEED_NODE=1
fi
if [[ "${NEED_NODE}" == "1" ]]; then
  echo "  - Installiere Node.js 22 (NodeSource) ..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y --no-install-recommends nodejs
fi
echo "  - node: $(node --version), npm: $(npm --version)"
echo "  - python: $("${PYTHON_BIN}" --version)"

echo "[2/8] Verzeichnisse ..."
mkdir -p "${BASE_DIR}" "${UPSTREAM_DIR}"

echo "[3/8] Upstream Vibe-Trading klonen/aktualisieren ..."
if [[ -d "${UPSTREAM_DIR}/.git" ]]; then
  git -C "${UPSTREAM_DIR}" fetch --all --prune
  git -C "${UPSTREAM_DIR}" checkout "${UPSTREAM_BRANCH}" 2>/dev/null || true
  git -C "${UPSTREAM_DIR}" pull --ff-only || git -C "${UPSTREAM_DIR}" reset --hard "origin/${UPSTREAM_BRANCH}"
else
  rm -rf "${UPSTREAM_DIR}"
  git clone --depth 1 --branch "${UPSTREAM_BRANCH}" "${UPSTREAM_REPO}" "${UPSTREAM_DIR}"
fi
git -C "${UPSTREAM_DIR}" log --oneline -1 || true

echo "[4/8] venv + Python-Abhängigkeiten (hash-gepinnte Locks, idempotent) ..."
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi
"${VENV_DIR}/bin/pip" install --upgrade pip wheel
"${VENV_DIR}/bin/pip" install --no-cache-dir --require-hashes \
  -r "${UPSTREAM_DIR}/requirements-lock.txt"
"${VENV_DIR}/bin/pip" install --no-cache-dir --require-hashes \
  -r "${UPSTREAM_DIR}/requirements-channels-lock.txt"
# CLI-Entrypoint (vibe-trading serve): --no-deps, Deps kommen aus den Locks.
"${VENV_DIR}/bin/pip" install --no-cache-dir --no-deps -e "${UPSTREAM_DIR}"
"${VENV_DIR}/bin/python" -c "import api_server; print('api_server import OK:', api_server.__file__)"
"${VENV_DIR}/bin/python" -c "import fastapi, uvicorn; print('web deps OK')"
"${VENV_DIR}/bin/vibe-trading" --help 2>&1 | head -n 15 || true

echo "[5/8] Frontend bauen (React + Vite -> frontend/dist, vom Server serviert) ..."
if [[ ! -f "${UPSTREAM_DIR}/frontend/package.json" ]]; then
  echo "WARN: frontend/package.json fehlt — UI-Build übersprungen." >&2
else
  cd "${UPSTREAM_DIR}/frontend"
  if [[ ! -d node_modules ]]; then
    npm ci --ignore-scripts
  else
    echo "  - node_modules vorhanden, überspringe npm ci (Update: npm ci bei Bedarf manuell)."
  fi
  npm run build
  cd - >/dev/null
fi
if [[ ! -d "${UPSTREAM_DIR}/frontend/dist" ]]; then
  echo "WARN: frontend/dist fehlt nach Build — Server startet trotzdem (API-only)." >&2
else
  echo "  - frontend/dist OK: $(du -sh "${UPSTREAM_DIR}/frontend/dist" | awk '{print $1}')"
fi

echo "[6/8] .env + Datenverzeichnisse ..."
if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${BASE_DIR}/repo-files/.env.example" ]]; then
    cp "${BASE_DIR}/repo-files/.env.example" "${ENV_FILE}"
  elif [[ -f "${UPSTREAM_DIR}/agent/.env.example" ]]; then
    cp "${UPSTREAM_DIR}/agent/.env.example" "${ENV_FILE}"
  else
    touch "${ENV_FILE}"
  fi
  echo "  - ${ENV_FILE} angelegt (Provider/Keys in der Web UI unter Settings eintragen)."
fi
chmod 600 "${ENV_FILE}" || true
mkdir -p "${UPSTREAM_DIR}/agent/runs" "${UPSTREAM_DIR}/agent/sessions" \
  "${UPSTREAM_DIR}/agent/uploads" "${UPSTREAM_DIR}/agent/.swarm/runs"

echo "[7/8] systemd-Unit ..."
if [[ -f "${BASE_DIR}/repo-files/systemd/vibe-trading.service" ]]; then
  cp "${BASE_DIR}/repo-files/systemd/vibe-trading.service" "${SERVICE_FILE}"
elif [[ -f "./systemd/vibe-trading.service" ]]; then
  cp "./systemd/vibe-trading.service" "${SERVICE_FILE}"
fi
# Port im Service sicherstellen (neutral gegenüber Template-Abweichungen)
if grep -q -- "--port" "${SERVICE_FILE}"; then
  sed -i -E "s/--port [0-9]+/--port ${WEB_PORT}/" "${SERVICE_FILE}"
fi
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo "[8/8] Verifikation ..."
sleep 4
echo "  - Service: $(systemctl is-active "${SERVICE_NAME}")"
systemctl is-active --quiet "${SERVICE_NAME}" || {
  echo "Service läuft NICHT. Journal:" >&2
  journalctl -u "${SERVICE_NAME}" --no-pager -n 100 >&2
  exit 1
}
echo "  - HTTP-Check auf localhost:${WEB_PORT} (/live, Fallback /health) ..."
for i in $(seq 1 15); do
  if curl -fsS "http://127.0.0.1:${WEB_PORT}/live" 2>&1 | head -c 300; then
    echo; echo "  - Web UI antwortet."
    break
  fi
  if curl -fsS "http://127.0.0.1:${WEB_PORT}/health" 2>&1 | head -c 300; then
    echo; echo "  - Web UI antwortet (via /health)."
    break
  fi
  if [[ "$i" == "15" ]]; then
    echo "Web UI antwortet NICHT nach 15 Versuchen. Journal:" >&2
    journalctl -u "${SERVICE_NAME}" --no-pager -n 100 >&2
    curl -v "http://127.0.0.1:${WEB_PORT}/live" >&2 || true
    exit 1
  fi
  sleep 2
done

CT_IP="$(hostname -I | awk '{print $1}')"
echo "=================================================================="
echo " Vibe-Trading Web UI: http://${CT_IP}:${WEB_PORT}"
echo " Service: systemctl status ${SERVICE_NAME}"
echo " Logs   : journalctl -u ${SERVICE_NAME} -f"
echo " Alles einstellbar in der Web UI: Provider, Modelle, API-Keys"
echo " (Settings), Research/Chat, Backtests, Scheduled, Options Lab."
echo " Erster Schritt: Settings öffnen -> Provider + Key eintragen."
echo " Reboot-Test: pct reboot <CTID> && nach Neustart URL erneut öffnen."
echo "=================================================================="
