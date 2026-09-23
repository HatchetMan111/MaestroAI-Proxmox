#!/usr/bin/env bash
#
# Maestro Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:     Maestro Studio (Web UI, Maestro CLI – mobiles UI-Testing)
# Upstream: https://github.com/mobile-dev-inc/Maestro
# Doku:     https://docs.maestro.dev/maestro-cli/how-to-install-maestro-cli
# Stack:    OpenJDK 17 + Maestro CLI (https://get.maestro.mobile.dev), nativ im LXC
# Läuft:   vollständig lokal im LXC, keine Cloud nötig
# Host:    DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MaestroAI-Proxmox/main/install/maestro.sh)"
#   CT_ID=101 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MaestroAI-Proxmox/main/install/maestro.sh)"
#   bash maestro.sh --ctid 101 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --debug
#
# Hinweis: Maestro Studio ('maestro studio --no-window') ist im aktuellen CLI
# ein versteckter Befehl und waehlt seinen Port dynamisch (bevorzugt 9999).
# Der Installer detektiert den echten Port und stellt ihn stabil auf 9999
# bereit (socat-Forward, nur falls noetig). Ohne verbundenes Device startet
# Studio trotzdem – ein Handy/Emulator kann spaeter extern verbunden werden.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="maestro"                               # Container-Hostname + Service-Name
STUDIO_PORT="9999"                          # Maestro Studio Web UI (Aussen-Port)
SERVICE_NAME="maestro-studio"               # systemd-Unit im LXC
MAESTRO_USER="maestro"                      # Nutzer im LXC, dem Maestro gehoert
MAESTRO_INSTALL_URL="https://get.maestro.mobile.dev"

DEFAULT_CORES="2"                           # vCPU
DEFAULT_RAM="2048"                          # RAM in MB (Java + Studio: min. 2048 empfohlen)
DEFAULT_SWAP="512"                          # Swap (MB)
DEFAULT_DISK="8"                            # Disk in GB (Java + Maestro: min. 8)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"              # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"             # Template-Familie
UNPRIVILEGED="1"

# Umgebungs-Overrides erlauben: CT_ID=101 CORES=4 RAM=4096 DISK=10 ./maestro.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
SCRIPT_ARGS="$*"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe zusätzlich ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer (Maestro Studio Web UI)

Usage:
  bash maestro.sh [OPTIONEN]
  CT_ID=101 bash maestro.sh
  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MaestroAI-Proxmox/main/install/maestro.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM}, Minimum 2048 empfohlen)
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --debug, -x          set -x + maximale Fehlermeldungskette
  --help, -h           diese Hilfe

Nach der Installation:
  Studio: http://<LXC-IP>:${STUDIO_PORT}
EOF
}

# ---------------------------------------------------------------------------
# Debugging: komplette Fehlermeldungskette (Stacktrace, stderr/stdout, Exit-Code, Logs)
# ---------------------------------------------------------------------------
on_error() {
  local exit_code="$1" lineno="$2" cmd="$3"
  set +x
  # Sehr lange Befehle (z. B. Heredoc-Blöcke) kürzen – das Log enthält alles.
  if ((${#cmd} > 2000)); then
    cmd="${cmd:0:2000}… [gekürzt, vollständiger Befehl in $LOG_FILE]"
  fi
  echo ""
  msg_error "════════════ INSTALLATION FEHLGESCHLAGEN ════════════"
  msg_error "Befehl    : $cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Args      : $SCRIPT_ARGS"
  msg_error "Logdatei  : $LOG_FILE (komplette stdout/stderr-Kette)"
  echo ""
  msg_error "--- Stacktrace (neuester Aufruf zuerst) ---"
  local i=0
  while caller "$i"; do ((i++)) || true; done
  echo ""
  if command -v pct >/dev/null 2>&1 && [[ -n "${CTID:-}" ]]; then
    msg_error "--- pct config ${CTID} ---"
    pct config "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- pct status ${CTID} ---"
    pct status "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- systemctl status im Container (maestro-studio) ---"
    pct exec "${CTID}" -- systemctl status "${SERVICE_NAME}" --no-pager --full 2>&1 || true
    echo ""
    msg_error "--- journalctl im Container (maestro-studio, letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- journalctl -u "${SERVICE_NAME}" --no-pager -n 100 2>&1 || true
    echo ""
    msg_error "--- maestro-Version im Container ---"
    pct exec "${CTID}" -- su - "${MAESTRO_USER}" -c '$HOME/.maestro/bin/maestro --version' 2>&1 || true
    echo ""
    msg_error "--- Ports im Container (ss -tlnp) ---"
    pct exec "${CTID}" -- ss -tlnp 2>&1 || true
  fi
  echo ""
  msg_error "Re-run mit vollem Trace:"
  # shellcheck disable=SC2086
  msg_error "  bash -x maestro.sh $SCRIPT_ARGS"
  msg_error "  oder: DEBUG=1 bash maestro.sh $SCRIPT_ARGS"
  msg_error "Bitte bei Fehlermeldungen IMMER die komplette Logdatei ($LOG_FILE) mitschicken."
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CTID="$CT_ID_ARG"
HOSTNAME_ARG="$APP"
CORES="$CORES_ARG"
RAM="$RAM_ARG"
DISK="$DISK_ARG"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
ROOT_PASSWORD=""
SSH_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)            CTID="${2:?--ctid braucht einen Wert}"; shift 2 ;;
    --hostname)        HOSTNAME_ARG="${2:?--hostname braucht einen Wert}"; shift 2 ;;
    --cores)           CORES="${2:?}"; shift 2 ;;
    --memory)          RAM="${2:?}"; shift 2 ;;
    --disk)            DISK="${2:?}"; shift 2 ;;
    --storage)         STORAGE_ARG="${2:?}"; shift 2 ;;
    --template-store)  TEMPLATE_STORE="${2:?}"; shift 2 ;;
    --bridge)          BRIDGE="${2:?}"; shift 2 ;;
    --password)        ROOT_PASSWORD="${2:?}"; shift 2 ;;
    --ssh-key)         SSH_KEY="${2:?}"; shift 2 ;;
    --debug|-x)        DEBUG="1"; set -x; shift ;;
    --help|-h)         usage; exit 0 ;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
done

# Trap NACH dem Parsen setzen, damit SCRIPT_ARGS die echten Args enthält
# shellcheck disable=SC2064
trap "on_error \$? \$LINENO \"\$BASH_COMMAND\"" ERR

# ---------------------------------------------------------------------------
# Pre-Checks (muss auf dem Proxmox-Host als root laufen)
# ---------------------------------------------------------------------------
msg_info "Prüfe Voraussetzungen (Proxmox-Host, root, Tools) ..."
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  msg_error "Bitte als root auf dem Proxmox-Host ausführen (sudo -i)."
  exit 1
fi
for bin in pct pveam pvesh pvesm wget curl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    msg_error "Benötigtes Tool fehlt: $bin – läuft das Skript wirklich auf einem Proxmox-VE-Host?"
    exit 1
  fi
done
if [[ "$RAM" -lt 2048 ]]; then
  msg_warn "RAM=${RAM} MB < 2048 MB – Java 17 + Maestro Studio brauchen min. 2 GB, sonst OOM."
fi
if [[ "$DISK" -lt 8 ]]; then
  msg_warn "DISK=${DISK} GB < 8 GB – Java + Maestro brauchen min. ~8 GB."
fi
msg_ok "Host-Checks bestanden."

# ---------------------------------------------------------------------------
# CT-ID: immer die nächste freie ID nehmen (außer explizit gesetzt)
# ---------------------------------------------------------------------------
if [[ -z "$CTID" ]]; then
  msg_info "Ermittle nächste freie CT-ID ..."
  CTID="$(pvesh get /cluster/nextid)"
  msg_ok "Nächste freie CT-ID: $CTID"
else
  msg_info "CT-ID vorgegeben: $CTID"
fi

HOSTNAME_FINAL="$HOSTNAME_ARG"
if [[ ! "$HOSTNAME_FINAL" =~ ^[a-zA-Z0-9-]+$ ]]; then
  msg_error "Ungültiger Hostname: $HOSTNAME_FINAL (nur Buchstaben, Zahlen, Bindestrich)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Storage-Erkennung (idempotent: vorhandene Storages nutzen)
# ---------------------------------------------------------------------------
detect_storage() {
  local s
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | grep -x "local-lvm" || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | head -n1 || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  echo "local-lvm"
}
if [[ -z "$STORAGE_ARG" ]]; then
  STORAGE_ARG="$(detect_storage)"
  msg_info "RootFS-Storage (auto): $STORAGE_ARG"
else
  msg_info "RootFS-Storage (vorgegeben): $STORAGE_ARG"
fi

# ---------------------------------------------------------------------------
# Template sicherstellen
# ---------------------------------------------------------------------------
msg_info "Aktualisiere Template-Liste (pveam update) ..."
pveam update

msg_info "Suche neuestes ${DEFAULT_OS}-Template auf ${TEMPLATE_STORE} ..."
TEMPLATE_FILE="$(pveam available --section system 2>/dev/null \
  | grep -o "${DEFAULT_OS}[^ ]*\\.tar\\.zst" | sort -V | tail -n1 || true)"
if [[ -z "$TEMPLATE_FILE" ]]; then
  msg_error "Kein Template für ${DEFAULT_OS} gefunden. Verfügbare Debian-Templates:"
  pveam available --section system 2>&1 | grep -i debian || true
  exit 1
fi
TEMPLATE_REF="${TEMPLATE_STORE}:vztmpl/${TEMPLATE_FILE}"
msg_info "Template: $TEMPLATE_REF"
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE_FILE"; then
  msg_info "Lade Template herunter (kann dauern) ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE_FILE"
else
  msg_ok "Template bereits vorhanden – Download übersprungen (idempotent)."
fi

# ---------------------------------------------------------------------------
# Container erstellen (idempotent: existiert die CT-ID schon, wiederverwenden)
# ---------------------------------------------------------------------------
CREATED_NOW=0
GENERATED_PW=0
if pct status "$CTID" >/dev/null 2>&1; then
  msg_warn "Container $CTID existiert bereits – wird wiederverwendet (idempotent, kein Neu-Erstellen)."
  EXISTING_HOST="$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}' || true)"
  msg_info "Bestehender Hostname: ${EXISTING_HOST:-unbekannt}"
else
  if [[ -z "$ROOT_PASSWORD" ]]; then
    ROOT_PASSWORD="$(openssl rand -hex 8)"
    GENERATED_PW=1
  fi
  msg_info "Erstelle LXC $CTID (hostname=${HOSTNAME_FINAL}, cores=${CORES}, ram=${RAM}MB, disk=${DISK}G) ..."
  CREATE_ARGS=(
    "$CTID" "$TEMPLATE_REF"
    --hostname "$HOSTNAME_FINAL"
    --cores "$CORES"
    --memory "$RAM"
    --swap "$DEFAULT_SWAP"
    --rootfs "${STORAGE_ARG}:${DISK}"
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
    --ostype debian
    --unprivileged "$UNPRIVILEGED"
    --onboot 1
    --start 0
    --password "$ROOT_PASSWORD"
  )
  if [[ -n "$SSH_KEY" ]]; then
    if [[ ! -f "$SSH_KEY" ]]; then msg_error "SSH-Key nicht gefunden: $SSH_KEY"; exit 1; fi
    CREATE_ARGS+=(--ssh-public-keys "$SSH_KEY")
  fi
  pct create "${CREATE_ARGS[@]}"
  pct set "$CTID" --onboot 1
  CREATED_NOW=1
  msg_ok "Container $CTID erstellt (Name: $HOSTNAME_FINAL, onboot=1, unprivilegiert)."
fi

msg_info "Starte Container $CTID ..."
if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
  pct start "$CTID"
fi
for i in $(seq 1 30); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
  sleep 2
  if [[ "$i" -eq 30 ]]; then msg_error "Container $CTID reagiert nicht auf 'pct exec'."; exit 1; fi
done
msg_ok "Container $CTID läuft."

sleep 5

# ---------------------------------------------------------------------------
# Installation IM Container (idempotentes Setup-Skript via pct push + exec)
# ---------------------------------------------------------------------------
msg_info "Installiere ${APP} im Container (Java 17 + Maestro CLI + Studio-Service) ..."

# systemd-Unit-Vorlage (identisch zu systemd/maestro-studio.service im Repo)
read -r -d '' UNIT_FILE <<'UNIT_EOF' || true
[Unit]
Description=Maestro Studio – Web UI fuer mobiles UI-Testing (Maestro CLI)
Documentation=https://docs.maestro.dev/maestro-cli/how-to-install-maestro-cli
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=maestro
Group=maestro
WorkingDirectory=/home/maestro
Environment=JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
Environment=PATH=/usr/lib/jvm/java-17-openjdk-amd64/bin:/home/maestro/.maestro/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/opt/maestro/run-studio.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT_EOF

# Wrapper-Skript SEPARAT bauen (QUOTED Heredoc = KEINE Host-Expansion;
# dadurch kann kein Container-$ mehr auf dem Host expandieren – genau das
# ist vorher mit '$4: unbound variable' abgebrochen). Der Studio-Port wird
# per Platzhalter eingesetzt und per sed auf den Host-Wert gesetzt.
TMP_RUNNER="$(mktemp /tmp/maestro-runner.XXXXXX.sh)"
cat > "$TMP_RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
# Startet 'maestro studio --no-window' und stellt es stabil auf 0.0.0.0:9999 bereit.
# Hintergrund: Studio waehlt seinen Port dynamisch (bevorzugt 9999). Falls es auf
# einem anderen Port landet, forwarded socat 9999 -> echter Port (wenn 9999 frei).
set -euo pipefail
STUDIO_PORT="__STUDIO_PORT__"
MAESTRO_BIN="/home/maestro/.maestro/bin/maestro"
LOG="/var/log/maestro-studio.log"

detect_java_port() {
  ss -tlnp 2>/dev/null | awk '/java/ {print $4}' | grep -oE '[0-9]+$' | sort -un | head -n1 || true
}

# Alte Forwarder aufraeumen
pkill -f "socat TCP-LISTEN:${STUDIO_PORT}" 2>/dev/null || true

"$MAESTRO_BIN" studio --no-window >>"$LOG" 2>&1 &
STUDIO_PID=$!
echo "[studio] Maestro Studio gestartet (PID $STUDIO_PID), warte auf Listen-Port ..."

ACTUAL=""
for i in $(seq 1 60); do
  sleep 2
  if ! kill -0 "$STUDIO_PID" 2>/dev/null; then
    echo "[studio][ERROR] Studio-Prozess starb frueh – Log:" >&2
    tail -n 50 "$LOG" >&2 || true
    exit 1
  fi
  ACTUAL="$(detect_java_port)"
  if [[ -n "$ACTUAL" ]]; then
    echo "[studio] Studio lauscht auf Port $ACTUAL."
    echo "$ACTUAL" > /run/maestro-studio-port
    break
  fi
done
if [[ -z "${ACTUAL:-}" ]]; then
  echo "[studio][ERROR] Kein Java-Listen-Port nach 120s – Log:" >&2
  tail -n 50 "$LOG" >&2 || true
  kill "$STUDIO_PID" 2>/dev/null || true
  exit 1
fi

if [[ "$ACTUAL" == "$STUDIO_PORT" ]]; then
  echo "[studio] Studio laeuft direkt auf $STUDIO_PORT – kein Forward noetig."
  wait "$STUDIO_PID"
else
  echo "[studio] Forward 0.0.0.0:$STUDIO_PORT -> 127.0.0.1:$ACTUAL via socat."
  socat "TCP-LISTEN:${STUDIO_PORT},fork,reuseaddr,bind=0.0.0.0" "TCP:127.0.0.1:${ACTUAL}" &
  SOCAT_PID=$!
  # Wenn Studio stirbt, stirbt der Wrapper (systemd startet neu).
  wait "$STUDIO_PID"
  STATUS=$?
  kill "$SOCAT_PID" 2>/dev/null || true
  exit "$STATUS"
fi
RUNNER_EOF
sed -i "s/__STUDIO_PORT__/${STUDIO_PORT}/" "$TMP_RUNNER"
chmod 0644 "$TMP_RUNNER"

# Setup-Skript lokal bauen (Host-Variablen werden HIER expandiert,
# Container-Variablen sind mit \$ escaped und werden ERST im LXC expandiert).
TMP_SETUP="$(mktemp /tmp/maestro-setup.XXXXXX.sh)"
cat > "$TMP_SETUP" <<SETUP_EOF
#!/usr/bin/env bash
set -euo pipefail
APP="${APP}"
STUDIO_PORT="${STUDIO_PORT}"
SERVICE_NAME="${SERVICE_NAME}"
MAESTRO_USER="${MAESTRO_USER}"
MAESTRO_INSTALL_URL="${MAESTRO_INSTALL_URL}"

echo "[LXC] apt update + Basis-Pakete ..."
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C LANG=C
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates socat iproute2 procps openssl unzip

echo "[LXC] Java 17 sicherstellen (idempotent) ..."
if ! java -version 2>&1 | grep -qE '"(17|18|19|2[0-9])'; then
  apt-get install -y --no-install-recommends openjdk-17-jdk
else
  echo "[LXC] Java bereits vorhanden: \$(java -version 2>&1 | head -n1)"
fi
java -version 2>&1 | head -n1
if [[ ! -d /usr/lib/jvm/java-17-openjdk-amd64 ]]; then
  echo "[LXC][WARN] JAVA_HOME-Pfad /usr/lib/jvm/java-17-openjdk-amd64 fehlt – suche JDK ..." >&2
  ls /usr/lib/jvm/ >&2 || true
fi

echo "[LXC] Nutzer \$MAESTRO_USER sicherstellen ..."
id "\$MAESTRO_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "\$MAESTRO_USER"

echo "[LXC] Maestro CLI installieren/aktualisieren (Upstream-Installer, idempotent) ..."
su - "\$MAESTRO_USER" -c "curl -fsSL --retry 3 --max-time 120 '\$MAESTRO_INSTALL_URL' | bash"
su - "\$MAESTRO_USER" -c '\$HOME/.maestro/bin/maestro --version' || {
  echo "[LXC][ERROR] 'maestro --version' schlaegt fehl – Installation pruefen." >&2
  su - "\$MAESTRO_USER" -c 'ls -la \$HOME/.maestro/bin/' >&2 || true
  exit 1
}
echo "[LXC] maestro --help (Kurz-Check) ..."
su - "\$MAESTRO_USER" -c '\$HOME/.maestro/bin/maestro --help' | head -n 20 || true

echo "[LXC] Pruefe ob 'maestro studio' in dieser CLI-Version existiert ..."
if su - "\$MAESTRO_USER" -c '\$HOME/.maestro/bin/maestro --help' | grep -q "studio"; then
  echo "[LXC] 'maestro studio' gefunden."
else
  echo "[LXC][WARN] 'maestro studio' taucht in --help NICHT auf (neue CLI: Studio entbuendelt, Befehl hidden/entfernt)." >&2
  echo "[LXC][WARN] Versuche trotzdem 'maestro studio --help' – falls das fehlschlaegt, bleibt nur die CLI nutzbar." >&2
  if ! su - "\$MAESTRO_USER" -c '\$HOME/.maestro/bin/maestro studio --help' >/dev/null 2>&1; then
    echo "[LXC][ERROR] Diese Maestro-Version liefert KEIN 'maestro studio' mehr (Desktop-App statt Web-Studio)." >&2
    echo "[LXC][ERROR] CLI ist installiert und nutzbar (pct enter <CT> als maestro), aber es gibt keine Web UI." >&2
    echo "[LXC][ERROR] Entweder aeltere CLI pinnen oder Maestro Studio Desktop nutzen: https://maestro.dev" >&2
    exit 1
  fi
fi

echo "[LXC] Wrapper /opt/maestro/run-studio.sh einrichten (per pct push uebertragen) ..."
mkdir -p /opt/maestro
cp /tmp/run-studio.sh /opt/maestro/run-studio.sh
chmod +x /opt/maestro/run-studio.sh
touch /var/log/maestro-studio.log
chown "\$MAESTRO_USER:\$MAESTRO_USER" /var/log/maestro-studio.log

echo "[LXC] systemd-Unit schreiben ..."
cat > /etc/systemd/system/\$SERVICE_NAME.service <<UNIT_INNER_EOF
${UNIT_FILE}
UNIT_INNER_EOF
systemctl daemon-reload
systemctl enable "\$SERVICE_NAME"

echo "[LXC] Service (neu) starten ..."
if systemctl is-active --quiet "\$SERVICE_NAME"; then
  systemctl restart "\$SERVICE_NAME"
else
  systemctl start "\$SERVICE_NAME"
fi
sleep 5

# HTTP-Probe: JEDE HTTP-Antwort (auch 404) zaehlt als "antwortet" – nur 000
# (keine TCP-Verbindung) ist ein Fehler.
wait_for_http() {
  local label="\$1" url="\$2"
  local i code
  for i in \$(seq 1 90); do
    code="\$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "\$url" 2>/dev/null || true)"
    [[ -z "\$code" ]] && code="000"
    if [[ "\$code" != "000" ]]; then
      echo "[LXC] \$label antwortet (HTTP \$code auf \$url)."
      return 0
    fi
    if [[ \$((i % 12)) -eq 0 ]]; then echo "[LXC] ... warte auf \$label (\$((i*2))s), Ports:"; ss -tlnp | head -n 10 || true; fi
    sleep 2
  done
  echo "[LXC][ERROR] \$label antwortet nicht auf \$url (keine TCP/HTTP-Antwort)." >&2
  return 1
}

echo "[LXC] Warte auf Studio (http://127.0.0.1:\$STUDIO_PORT, max 180s) ..."
EFFECTIVE_PORT="\$STUDIO_PORT"
if [[ -f /run/maestro-studio-port ]]; then
  DETECTED="\$(cat /run/maestro-studio-port 2>/dev/null | tr -d ' \\n' || true)"
  [[ -n "\$DETECTED" ]] && EFFECTIVE_PORT="\$DETECTED"
fi
if ! wait_for_http "Studio" "http://127.0.0.1:\$EFFECTIVE_PORT"; then
  # Fallback: vielleicht laeuft Studio auf einem anderen dynamischen Port.
  DETECTED="\$(ss -tlnp 2>/dev/null | awk '/java/ {print \$4}' | grep -oE '[0-9]+\$' | sort -un | head -n1 || true)"
  if [[ -n "\$DETECTED" && "\$DETECTED" != "\$EFFECTIVE_PORT" ]]; then
    echo "[LXC] Versuche erkannten Java-Port \$DETECTED ..."
    if wait_for_http "Studio (Port \$DETECTED)" "http://127.0.0.1:\$DETECTED"; then
      echo "\$DETECTED" > /run/maestro-studio-port
      EFFECTIVE_PORT="\$DETECTED"
    fi
  fi
fi
if ! curl -s -o /dev/null --max-time 5 "http://127.0.0.1:\$EFFECTIVE_PORT" 2>/dev/null; then
  echo "[LXC][ERROR] Studio-Diagnose:" >&2
  systemctl status "\$SERVICE_NAME" --no-pager --full >&2 || true
  journalctl -u "\$SERVICE_NAME" --no-pager -n 100 >&2 || true
  tail -n 50 /var/log/maestro-studio.log >&2 || true
  ss -tlnp >&2 || true
  exit 1
fi

echo "[LXC] Service aktiv: \$(systemctl is-active \$SERVICE_NAME)"
echo "[LXC] Studio-Port (effektiv): \$EFFECTIVE_PORT"
SETUP_EOF

chmod 0644 "$TMP_SETUP"
msg_info "Setup-Skript lokal: $TMP_SETUP (Kopie bleibt zur Fehlersuche erhalten)"
pct push "$CTID" "$TMP_RUNNER" /tmp/run-studio.sh
pct push "$CTID" "$TMP_SETUP" /tmp/maestro-setup.sh
pct exec "$CTID" -- bash /tmp/maestro-setup.sh
msg_ok "Installation im Container abgeschlossen."

# ---------------------------------------------------------------------------
# Verifikation vom Host aus (Service + HTTP + IP)
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."

SERVICE_STATE="$(pct exec "$CTID" -- systemctl is-active "$SERVICE_NAME" 2>&1 || true)"
if [[ "$SERVICE_STATE" != "active" ]]; then
  msg_error "Service-Check fehlgeschlagen: 'systemctl is-active $SERVICE_NAME' = '$SERVICE_STATE' (erwartet: active)"
  pct exec "$CTID" -- systemctl status "$SERVICE_NAME" --no-pager --full || true
  pct exec "$CTID" -- journalctl -u "$SERVICE_NAME" --no-pager -n 100 || true
  exit 1
fi
msg_ok "Service läuft (systemctl is-active $SERVICE_NAME = active)."

# Effektiven Port aus dem Container holen (meist 9999, dynamisch möglich).
EFFECTIVE_PORT="$(pct exec "$CTID" -- cat /run/maestro-studio-port 2>/dev/null | tr -d ' \n' || true)"
[[ -z "$EFFECTIVE_PORT" ]] && EFFECTIVE_PORT="$STUDIO_PORT"

# HTTP-Code statt -f: JEDE Antwort zaehlt als "lebt", nur 000 (kein TCP) ist Fehler.
STUDIO_CODE="$(pct exec "$CTID" -- curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:${EFFECTIVE_PORT}" 2>/dev/null || true)"
[[ -z "$STUDIO_CODE" ]] && STUDIO_CODE="000"
if [[ "$STUDIO_CODE" == "000" ]]; then
  msg_error "HTTP-Check fehlgeschlagen: Studio http://127.0.0.1:${EFFECTIVE_PORT} antwortet nicht (keine Verbindung)."
  pct exec "$CTID" -- journalctl -u "$SERVICE_NAME" --no-pager -n 100 --no-color || true
  pct exec "$CTID" -- tail -n 50 /var/log/maestro-studio.log || true
  pct exec "$CTID" -- ss -tlnp || true
  exit 1
fi
msg_ok "Studio antwortet (HTTP $STUDIO_CODE auf localhost:${EFFECTIVE_PORT})."

MAESTRO_VERSION="$(pct exec "$CTID" -- su - "$MAESTRO_USER" -c "\$HOME/.maestro/bin/maestro --version" 2>/dev/null || true)"

CT_IP="$(pct exec "$CTID" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
[[ -z "$CT_IP" ]] && CT_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

# Externe Erreichbarkeit vom Host aus pruefen (faellt z. B. bei localhost-only-Bind auf).
EXT_OK=0
if [[ -n "${CT_IP:-}" ]]; then
  if curl -s -o /dev/null --max-time 10 "http://${CT_IP}:${STUDIO_PORT}" 2>/dev/null; then
    EXT_OK=1
  elif [[ "$EFFECTIVE_PORT" != "$STUDIO_PORT" ]] && curl -s -o /dev/null --max-time 10 "http://${CT_IP}:${EFFECTIVE_PORT}" 2>/dev/null; then
    EXT_OK=1
    STUDIO_PORT="$EFFECTIVE_PORT"
  fi
fi
if [[ "$EXT_OK" != "1" && -n "${CT_IP:-}" ]]; then
  msg_warn "Studio antwortet lokal, aber http://${CT_IP}:${STUDIO_PORT} ist vom Host NICHT erreichbar."
  msg_warn "Moeglich: Studio bindet nur localhost. Abhilfe: im Container 'ss -tlnp' pruefen,"
  msg_warn "ggf. SSH-Tunnel: ssh -L 9999:127.0.0.1:${EFFECTIVE_PORT} root@${CT_IP}"
fi

echo ""
echo -e "${C_GREEN}${C_BOLD}════════════════ INSTALLATION ERFOLGREICH ════════════════${C_RESET}"
echo -e "  App          : ${C_BOLD}Maestro Studio – Web UI für mobiles UI-Testing${C_RESET}"
echo -e "  Container    : CT ${C_BOLD}${CTID}${C_RESET} (Hostname: ${C_BOLD}${HOSTNAME_FINAL}${C_RESET}, onboot=1)"
echo -e "  Ressourcen   : ${CORES} vCPU / ${RAM} MB RAM / ${DISK} GB Disk"
if [[ -n "${CT_IP:-}" ]]; then
echo -e "  Studio       : ${C_BOLD}http://${CT_IP}:${STUDIO_PORT}${C_RESET}"
else
echo -e "  Studio       : ${C_BOLD}http://<LXC-IP>:${STUDIO_PORT}${C_RESET} (IP konnte nicht auto-ermittelt werden: pct exec $CTID -- ip a)"
fi
[[ -n "${MAESTRO_VERSION:-}" ]] && echo -e "  CLI          : ${MAESTRO_VERSION}"
echo -e "  Hinweis      : Studio startet auch OHNE verbundenes Device (leer). Device später extern verbinden."
echo -e "  CLI im CT   : pct enter ${CTID} → su - ${MAESTRO_USER} → maestro --help | maestro test flow.yaml"
if [[ "$CREATED_NOW" == "1" && "$GENERATED_PW" == "1" ]]; then
echo -e "  Root-Passwort: ${C_BOLD}${ROOT_PASSWORD}${C_RESET} (nur jetzt angezeigt – sicher ablegen!)"
fi
echo -e "  Service      : systemctl status ${SERVICE_NAME}  (im Container via: pct enter ${CTID})"
echo -e "  Logs         : journalctl -u ${SERVICE_NAME} -f + /var/log/maestro-studio.log (im Container)"
echo -e "  Update       : Skript erneut laufen lassen (idempotent, aktualisiert Maestro CLI + restart)"
echo -e "  Deinstall    : pct stop ${CTID} && pct destroy ${CTID}"
echo -e "  Reboot-Test  : pct reboot ${CTID} && sleep 45 && curl -fs http://${CT_IP:-<LXC-IP>}:${STUDIO_PORT} >/dev/null && echo STUDIO-OK"
echo -e "  Log          : ${LOG_FILE}"
echo -e "  Setup-Kopie  : ${TMP_SETUP}"
if [[ "$DEBUG" != "1" ]]; then
echo -e "  Debug bei Fehlern: ${C_CYAN}bash -x maestro.sh --ctid ${CTID}${C_RESET}"
fi
echo -e "${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
