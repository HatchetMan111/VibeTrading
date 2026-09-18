# Vibe-Trading — Proxmox LXC Installer + native Web UI

Lokale [Vibe-Trading](https://github.com/HKUDS/Vibe-Trading)-Installation
(„Your Personal Trading Agent": Finance-Research, Backtests, Swarm, QuantLib)
als **LXC-Container auf Proxmox VE** im Stil der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/):
**Einzeiler auf dem Host → Container + App + Web UI + systemd läuft.**

> Upstream: [HKUDS/Vibe-Trading](https://github.com/HKUDS/Vibe-Trading)
> (Python 3.11 / FastAPI + React/Vite, `vibe-trading serve`).
> Die **Web UI ist nativ enthalten** (`frontend/dist` wird vom API-Server
> serviert) — **alles lässt sich im Browser einstellen**: Provider, Modelle,
> API-Keys (Settings), Research/Chat, Backtests, Scheduled Research,
> Options Lab, Reports. Dieses Repo baut nur den Installer + systemd darum.

| Feld | Wert |
|---|---|
| App-Name | `vibe-trading` |
| Zweck | Natural-language Finance-Research + Backtesting lokal im LXC, Bedienung per Web UI |
| Tech-Stack | Python 3.11 / FastAPI + Uvicorn, React 19 + Vite (Node 22), LangGraph/LangChain |
| Upstream-Repo | https://github.com/HKUDS/Vibe-Trading |
| Web-UI-Port | `8899` (konfigurierbar, Default wie Dockerfile) |
| Health-Endpoints | `/live` (Liveness, Fallback `/health`) |
| Default-Ressourcen | 4 vCPU · 4096 MB RAM · 20 GB Disk · Debian 12 LXC, `onboot: 1` |

## 1 · Installation (Einzeiler auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VibeTrading/main/install/vibe-trading.sh)"
```

Das Script fragt interaktiv ab (mit sinnvollen Defaults):
`CT-ID` (152) · Hostname · vCPU (4) · RAM (4096) · Disk (20G) ·
Storage (`local-lvm`) · Template-Storage (`local`) · Bridge (`vmbr0`, DHCP) ·
Web-Port (8899).

Danach läuft vollautomatisch:
1. Debian-12-Template sicherstellen (`pveam download` falls nötig)
2. `pct create` + `onboot: 1` + Start
3. Wrapper-Dateien per `pct push` in den Container
4. `install/setup-container.sh` im Container: Systempakete
   (Python 3.11, Node 22, build-essential, WeasyPrint-Libs), Upstream-Clone,
   venv + hash-gepinnte Locks (`requirements-lock.txt`,
   `requirements-channels-lock.txt`), `pip install -e .`,
   Frontend-Build (`npm ci` + `npm run build` → `frontend/dist`),
   `agent/.env`, systemd-Unit `vibe-trading.service`
   (`enable`, `Restart=always`, `After=network-online.target`)
5. Selbst-Verifikation: `systemctl is-active` + HTTP-Check auf
   `localhost:8899/live`

**Erwartete Ausgabe (Ende):**

```text
[8/8] Verifikation ...
  - Service: active
  - HTTP-Check auf localhost:8899 (/live, Fallback /health) ...
{"status":"alive",...}
  - Web UI antwortet.
==================================================================
 Vibe-Trading Web UI: http://192.168.1.52:8899
 ...
==================================================================
 ✅ Fertig! Vibe-Trading Web UI: http://192.168.1.52:8899
    CT-ID 152 (vibe-trading), onboot=1, Service=vibe-trading
```

Web UI öffnen → **Schritt 1**: Settings → Provider + API-Key eintragen
(z. B. OpenRouter) → **Schritt 2**: Research/Backtest starten → Reports ansehen.

## 2 · Update / neuer Container

**Update im bestehenden Container** (Upstream pull, Deps + Frontend neu,
Service restart — `setup-container.sh` ist idempotent, mehrfach lauffähig):

```bash
pct exec 152 -- bash /opt/vibe-trading/setup-container.sh
```

**Neuer Container:** Einfach den Einzeiler erneut ausführen — ist die
angefragte CT-ID belegt, wird **automatisch die nächste freie genommen**
(z. B. 152 belegt → 153), ohne Rückfrage.

## 3 · Deinstallation

```bash
pct stop 152 && pct destroy 152
```

## 4 · Reboot-Test (Nachweis Reboot-Sicherheit)

```bash
pct reboot 152
sleep 30
pct exec 152 -- systemctl is-active vibe-trading   # -> active
curl -fsS http://<LXC-IP>:8899/live                 # -> {"status":"alive",...}
# Web UI im Browser neu laden -> wieder erreichbar
```

Container startet durch `onboot: 1` nach Host-Reboot automatisch;
die Web UI durch `systemctl enable` + `Restart=always`.

## 5 · Debugging (volle Fehlerkette)

- Installer mit Trace: `DEBUG=1 bash -x install/vibe-trading.sh`
- Setup im Container: `DEBUG=1 bash -x /opt/vibe-trading/setup-container.sh`
- Service-Logs: `pct exec 152 -- journalctl -u vibe-trading -f`
- Installer + Setup geben bei Fehlern **immer die komplette Kette** aus
  (Befehl, Zeile, Funktions-Stack, Exit-Code, Journal-Auszug) — nie nur 1 Zeile.

## 6 · Repo-Struktur

```text
install/vibe-trading.sh      Host-Installer (Einzeiler, Community-Scripts-Stil)
install/setup-container.sh   Setup IM Container (idempotent, set -euo pipefail)
systemd/vibe-trading.service systemd-Unit (enable, Restart=always)
.env.example                 Beispiel-Keys/Defaults (→ agent/.env)
```

## 7 · Hinweise

- **LXC vs. VM:** Standard ist LXC (leicht, ideal für Remote-LLM-APIs wie
  OpenRouter/OpenAI/Anthropic/Gemini). Nur wer **lokale** Modelle
  (Ollama/vLLM mit viel RAM/GPU) will, sollte stattdessen eine **VM**
  (z. B. 4–8 vCPU / 8–16 GB RAM / 40 GB) mit Debian 12 nehmen —
  `install/setup-container.sh` läuft dort unverändert
  (Debian 12 vorausgesetzt); `OLLAMA_BASE_URL` dann auf die Ollama-Adresse
  zeigen (im LXC ist `localhost` der Container selbst).
- **LAN-Zugriff:** Ohne `API_AUTH_KEY` läuft der Server im Loopback-Dev-Modus
  (Browser am gleichen Origin OK). Für echte LAN-/API-Nutzung einen Key in
  `agent/.env` (`API_AUTH_KEY=...`) setzen — in der Web UI unter Settings.
- **Keine Anlageberatung:** Upstream ist ein Research-Framework; Ergebnisse
  sind nicht-deterministisch (LLM-Sampling + Live-Daten). Siehe Upstream-README.
