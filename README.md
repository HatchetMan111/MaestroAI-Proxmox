# Maestro Studio auf Proxmox LXC – Einzeiler-Installation

> **Hinweis: Das ist NICHT das Maestro-App-Repository.**
> Dieses Repo enthält **nur den Proxmox-LXC-Installer** für Maestro Studio —
> keinen App-Code.
> Die eigentliche Anwendung liegt bei Upstream:
> `https://github.com/mobile-dev-inc/Maestro`. Das Install-Script nutzt deren
> offiziellen Installer (`https://get.maestro.mobile.dev`) plus OpenJDK 17 —
> alles läuft vollständig lokal.

Maestro (mobiles UI-Testing, YAML-Flows) läuft in einem unprivilegierten
LXC-Container nativ (Java 17 + Maestro CLI): Studio-Web-UI auf Port **9999**,
systemd-Service mit `Restart=always`, Container mit `onboot=1`.

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `maestro` |
| Zweck | Maestro Studio Web UI + Maestro CLI (mobile UI-Tests) |
| Tech-Stack | OpenJDK 17 + Maestro CLI (nativ, kein Docker) |
| Upstream-Repo | `https://github.com/mobile-dev-inc/Maestro` |
| Upstream-Doku | `https://docs.maestro.dev/maestro-cli/how-to-install-maestro-cli` |
| Web UI | `http://<LXC-IP>:9999` (Maestro Studio) |
| Standard-Ressourcen | 2 vCPU / 2048 MB RAM / 8 GB Disk |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | keine nötig (kein Docker), unprivilegiert |

> **Braucht Studio ein Device?** Nein — Studio startet auch ohne verbundenes
> Device (dann leer). Handy/Emulator später extern verbinden und in Studio
> bzw. per `maestro --host ...` ansprechen. Im LXC selbst läuft kein
> Emulator (dafür wäre KVM nötig).

## 1. Installation (Einzeiler, auf dem Proxmox-Host als root)

Einfach kopieren und auf dem Proxmox-Host als `root` einfügen
(Community-Scripts-Stil, keine weitere Datei nötig):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MaestroAI-Proxmox/main/install/maestro.sh)"
```

Anpassungen wahlweise per Umgebungsvariable oder Flag:

```bash
CT_ID=101 CORES=4 RAM=4096 DISK=10 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MaestroAI-Proxmox/main/install/maestro.sh)"
bash maestro.sh --ctid 101 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --storage local-lvm
bash maestro.sh --debug   # = bash -x, maximale Fehlermeldungskette
```

Das Skript (`set -euo pipefail`, idempotent):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `maestro` (`onboot: 1`, unprivilegiert),
3. installiert im Container OpenJDK 17 + Maestro CLI als User `maestro`
   (`curl -fsSL https://get.maestro.mobile.dev | bash`), legt
   `/opt/maestro/run-studio.sh` + systemd-Unit `maestro-studio` an,
   `systemctl enable --now maestro-studio`,
4. verifiziert `systemctl is-active maestro-studio` + HTTP auf Studio-Port
   und gibt die finale URL + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active maestro-studio = active).
[OK]    Studio antwortet (HTTP 200 auf localhost:9999).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Maestro Studio – Web UI für mobiles UI-Testing
  Container    : CT 100 (Hostname: maestro, onboot=1)
  Ressourcen   : 2 vCPU / 2048 MB RAM / 8 GB Disk
  Studio       : http://192.168.1.100:9999
  CLI          : maestro 1.39.0
  Hinweis      : Studio startet auch OHNE verbundenes Device (leer). Device später extern verbinden.
  CLI im CT   : pct enter 100 → su - maestro → maestro --help | maestro test flow.yaml
  Root-Passwort: aB3... (nur jetzt angezeigt – sicher ablegen!)
  Service      : systemctl status maestro-studio  (im Container via: pct enter 100)
  Logs         : journalctl -u maestro-studio -f + /var/log/maestro-studio.log (im Container)
  Update       : Skript erneut laufen lassen (idempotent, aktualisiert Maestro CLI + restart)
  Deinstall    : pct stop 100 && pct destroy 100
  Reboot-Test  : pct reboot 100 && sleep 45 && curl -fs http://192.168.1.100:9999 >/dev/null && echo STUDIO-OK
  Log          : /tmp/maestro-install-2026-....log
══════════════════════════════════════════════════════════
```

## 2. Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 45   # Java + Studio brauchen ~20–40 s nach Reboot
pct exec $CT -- systemctl is-active maestro-studio   # muss: active
curl -fs http://$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1):9999 >/dev/null && echo STUDIO-OK
pct config $CT | grep -i onboot              # muss: onboot: 1
```

## 3. Update (idempotent – einfach erneut laufen lassen)

```bash
bash maestro.sh --ctid 100
# aktualisiert Maestro CLI (Upstream-Installer), schreibt Unit/Wrapper neu,
# danach `systemctl restart maestro-studio`.
```

Manuell im Container:

```bash
pct enter 100
su - maestro
~/.maestro/bin/maestro --version
~/.maestro/bin/maestro --help
systemctl restart maestro-studio && systemctl status maestro-studio --no-pager --full
curl -fs http://127.0.0.1:9999 >/dev/null && echo STUDIO-OK
```

## 4. Deinstallation

```bash
pct stop 100 && pct destroy 100
```

## 5. Debugging (komplette Fehlermeldungskette)

- Jeder Lauf loggt **stdout+stderr vollständig** nach `/tmp/maestro-install-<Datum>.log`.
- Bei Fehlern druckt das Skript: Befehl, Zeile, Exit-Code, Stacktrace
  (`caller`), `pct config`/`pct status`, `journalctl -u maestro-studio -n 100`,
  `maestro --version`, `ss -tlnp` — niemals nur die letzte Zeile.
- Re-run mit Trace:

```bash
bash -x maestro.sh --ctid 100
DEBUG=1 bash maestro.sh --ctid 100
# Log mitschicken:
tail -n 200 /tmp/maestro-install-*.log
pct exec 100 -- journalctl -u maestro-studio --no-pager -n 100
pct exec 100 -- tail -n 100 /var/log/maestro-studio.log
pct exec 100 -- ss -tlnp
```

## 6. Dateien in diesem Paket

```text
MaestroAI-Proxmox/               # dieses Repo: NUR Proxmox-Installer, kein App-Code
├── install/maestro.sh           # Proxmox-Install-Script (Community-Scripts-konform, Variablen oben)
├── systemd/maestro-studio.service  # systemd-Unit (Restart=always, After=network-online.target)
└── README.md                    # diese Datei
```

`install/maestro.sh` bettet die Unit-Vorlage aus
`systemd/maestro-studio.service` ein, damit der Einzeiler ohne weitere
Dateien auskommt. Der Wrapper `/opt/maestro/run-studio.sh` wird im
Container erzeugt.

## 7. Hinweise

- **Warum nativ statt Docker?** Upstream-Doku installiert per
  `curl ... | bash` + Java 17 — nativ im LXC sind das < 2 Minuten und
  ~1 GB statt Docker-Overhead. Kein `nesting` nötig.
- **Dynamischer Studio-Port:** `maestro studio` wählt seinen Port dynamisch
  (bevorzugt 9999, kein `--port`-Flag im Source). Der Wrapper detektiert den
  echten Java-Listen-Port (`ss -tlnp`) und forwarded ihn per `socat` stabil
  auf `0.0.0.0:9999` (nur falls nötig). Der effektive Port steht im Container
  unter `/run/maestro-studio-port`.
- **Studio-Befehl fehlt?** In neueren CLI-Versionen ist Studio entbündelt
  (hidden/entfernt zugunsten der Desktop-App). Dann bricht der Installer mit
  klarer Meldung ab — die CLI bleibt trotzdem nutzbar
  (`pct enter <CT>` → `su - maestro` → `maestro --help`). Alternative:
  ältere CLI pinnen oder Maestro Studio Desktop von `https://maestro.dev`.
- **localhost-only-Bind:** Falls Studio nur auf `127.0.0.1` lauscht, meldet
  der Installer es (lokal OK, extern vom Host nicht erreichbar) mit
  SSH-Tunnel-Abhilfe: `ssh -L 9999:127.0.0.1:9999 root@<LXC-IP>`.
- **DHCP-Hinweis:** Ändert sich die Container-IP, Installer erneut laufen
  lassen oder DHCP-Reservierung/statische IP einrichten.
- **Ressourcen:** Mit < 2 GB RAM droht OOM (JVM + Studio) — darum warnt das
  Skript bei kleineren Werten.
