#!/usr/bin/env bash
set -euo pipefail

############################################
# handover_inventory.sh (Ubuntu 20.04)
# - Installs required tools
# - Collects inventory into OUTDIR
# - Creates summary
# - Creates full archive (optional attach)
# - Creates light archive if full is too big
# - Sends email via SMTP (SMTPS 465) using msmtp + bsd-mailx
#
# Run:
#   sudo ./handover_inventory.sh
############################################

############################################
# CONFIG
############################################
SEND_TO="uebergabe@smarte-ki.de"
SMTP_USER="uebergabe@smarte-ki.de"
SMTP_SERVER="smarte-ki.de"
SMTP_PORT="465"

# Attachment limit (10 MiB)
MAX_ATTACH_BYTES=$((10 * 1024 * 1024))

APT_PACKAGES=(
  pciutils
  lshw
  dmidecode
  smartmontools
  nvme-cli
  jq
  util-linux
  msmtp
  msmtp-mta
  bsd-mailx
  ca-certificates
)

############################################
# PRECHECK
############################################
if [[ $EUID -ne 0 ]]; then
  echo "❌ Bitte mit sudo ausführen:"
  echo "sudo $0"
  exit 1
fi

echo "🔍 Prüfe & installiere notwendige Tools …"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null

for pkg in "${APT_PACKAGES[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "➕ Installiere $pkg"
    apt-get install -y "$pkg"
  fi
done

echo "✅ Toolchain vollständig"
echo

############################################
# OUTPUT SETUP
############################################
TS="$(date -u +"%Y-%m-%dT%H%M%SZ")"
HOST="$(hostname -s 2>/dev/null || hostname)"
OUTDIR="handover_${HOST}_${TS}"
mkdir -p "$OUTDIR"

log() { echo "➡ $1"; }

run() {
  local cmd="$1"
  local file="$2"
  {
    echo "### CMD: $cmd"
    echo
    eval "$cmd"
  } > "$OUTDIR/$file" 2> "$OUTDIR/${file}.err" || true
}

file_size() {
  # bytes
  local f="$1"
  if [[ -f "$f" ]]; then
    stat -c%s "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

############################################
# DATA COLLECTION
############################################
log "System"
run 'hostname; echo; hostname -f 2>/dev/null || true; echo; uname -a; echo; uptime -p || true; echo; cat /etc/os-release' "00_system.txt"

log "CPU"
run 'lscpu' "10_cpu.txt"

log "RAM"
run 'free -h; echo; cat /proc/meminfo | head -n 40; echo; dmidecode -t memory' "20_ram.txt"

log "GPUs"
if command -v nvidia-smi >/dev/null 2>&1; then
  run 'nvidia-smi' "30_gpu_overview.txt"
  run 'nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,serial,driver_version,vbios_version,memory.total --format=csv' "31_gpu_details.csv"
else
  echo "nvidia-smi nicht verfügbar" > "$OUTDIR/30_gpu_overview.txt"
  echo "nvidia-smi nicht verfügbar" > "$OUTDIR/31_gpu_details.csv"
fi

log "PCI"
run 'lspci -nn | sort' "40_pci.txt"
run 'lspci -nn | egrep -i "vga|3d|nvidia|amd|ethernet|network|infiniband" || true' "41_pci_filtered.txt"

log "Storage"
run 'lsblk -o NAME,MODEL,SERIAL,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID,ROTA,TRAN -e7' "50_storage_lsblk.txt"
run 'blkid || true' "51_storage_blkid.txt"
run 'df -hT || true' "52_storage_df.txt"
run 'nvme list 2>/dev/null || true' "53_nvme_list.txt"
run 'for d in /dev/nvme*n1; do [ -e "$d" ] || continue; echo "== $d =="; nvme id-ctrl "$d" || true; echo; done' "54_nvme_details.txt"

log "SMART"
run 'for d in /dev/sd? /dev/nvme?n1; do [ -e "$d" ] || continue; echo "== $d =="; smartctl -H -i "$d" || true; echo; done' "55_smart.txt"

log "Network"
run 'ip -br a || true; echo; ip r || true' "60_network.txt"
run 'lshw -class network -short 2>/dev/null || true' "61_network_hw.txt"

log "System Serials"
run 'dmidecode -t system -t baseboard -t chassis' "70_serials.txt"

############################################
# SUMMARY (ÜBERGABESEITE)
############################################
log "Erstelle Zusammenfassung"

CPU_MODEL="$(lscpu | awk -F: '/Model name/ {print $2}' | xargs || true)"
CPU_SOCKETS="$(lscpu | awk -F: '/Socket\(s\)/ {print $2}' | xargs || true)"
CPU_CORES="$(lscpu | awk -F: '/Core\(s\) per socket/ {print $2}' | xargs || true)"
CPU_THREADS="$(lscpu | awk -F: '/Thread\(s\) per core/ {print $2}' | xargs || true)"
RAM_TOTAL="$(free -h | awk '/Mem:/ {print $2}' || true)"

if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_COUNT="$(nvidia-smi -L | wc -l | tr -d ' ' || echo 0)"
  GPU_MODEL="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort | uniq || true)"
else
  GPU_COUNT="0"
  GPU_MODEL="nvidia-smi nicht verfügbar"
fi

DISK_TOTAL_TB="$(lsblk -d -b -o SIZE,TYPE 2>/dev/null | awk '$2=="disk"{s+=$1} END {if (s>0) printf "%.2f TB", s/1024/1024/1024/1024; else print "n/a"}')"
OS_PRETTY="$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"

SUMMARY_FILE="$OUTDIR/ZZ_ÜBERGABE_ZUSAMMENFASSUNG.txt"
{
  echo "=============================="
  echo "SERVER ÜBERGABE – HARDWARE"
  echo "=============================="
  echo
  echo "Host:            $HOST"
  echo "Timestamp (UTC): $TS"
  echo
  echo "CPU:"
  echo "  Modell:        ${CPU_MODEL:-n/a}"
  echo "  Sockets:       ${CPU_SOCKETS:-n/a}"
  echo "  Cores/Socket:  ${CPU_CORES:-n/a}"
  echo "  Threads/Core:  ${CPU_THREADS:-n/a}"
  echo
  echo "RAM:"
  echo "  Gesamt:        ${RAM_TOTAL:-n/a}"
  echo
  echo "GPU:"
  echo "  Anzahl:        ${GPU_COUNT:-n/a}"
  echo "  Modell(e):"
  echo "$GPU_MODEL" | sed 's/^/    - /'
  echo
  echo "Storage:"
  echo "  Gesamt Rohkapazität (alle Disks): ${DISK_TOTAL_TB:-n/a}"
  echo
  echo "OS:"
  echo "  ${OS_PRETTY:-n/a}"
  echo
  echo "Details siehe Einzelreports im Ordner:"
  echo "  $OUTDIR/"
} > "$SUMMARY_FILE"

############################################
# ARCHIVES (full + light)
############################################
log "Erstelle Archiv(e)"
FULL_ARCHIVE="${OUTDIR}.tar.gz"
tar -czf "$FULL_ARCHIVE" "$OUTDIR"

# Light archive (only the most useful small files)
LIGHT_ARCHIVE="${OUTDIR}_light.tar.gz"
tar -czf "$LIGHT_ARCHIVE" \
  -C "$OUTDIR" \
  "ZZ_ÜBERGABE_ZUSAMMENFASSUNG.txt" \
  "10_cpu.txt" \
  "20_ram.txt" \
  "30_gpu_overview.txt" \
  "31_gpu_details.csv" \
  "50_storage_lsblk.txt" \
  "52_storage_df.txt" \
  "53_nvme_list.txt" \
  "55_smart.txt" \
  "60_network.txt" \
  "70_serials.txt" \
  2>/dev/null || true

FULL_SIZE="$(file_size "$FULL_ARCHIVE")"
LIGHT_SIZE="$(file_size "$LIGHT_ARCHIVE")"

############################################
# EMAIL SEND (SMTP 465 / SMTPS)
############################################
log "E-Mail Versand vorbereiten"

read -r -s -p "SMTP Passwort für $SMTP_USER: " SMTP_PASS
echo

if ! command -v msmtp >/dev/null 2>&1; then
  echo "❌ msmtp nicht gefunden (sollte installiert sein)."
  exit 1
fi
if ! command -v mail >/dev/null 2>&1; then
  echo "❌ bsd-mailx (mail) nicht gefunden (sollte installiert sein)."
  exit 1
fi

FQDN="$(hostname -f 2>/dev/null || true)"
IP_LIST="$(hostname -I 2>/dev/null | xargs || true)"
SERIAL="$(dmidecode -s system-serial-number 2>/dev/null || true)"
BOARD_SERIAL="$(dmidecode -s baseboard-serial-number 2>/dev/null || true)"

MSMTP_CFG="$(mktemp)"
BODY_FILE="$(mktemp)"
cleanup() {
  rm -f "$MSMTP_CFG" "$BODY_FILE" 2>/dev/null || true
  unset SMTP_PASS
}
trap cleanup EXIT

cat > "$MSMTP_CFG" <<EOF
defaults
auth           on
tls            on
tls_starttls   off
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        $OUTDIR/msmtp.log

account        handover
host           $SMTP_SERVER
port           $SMTP_PORT
from           $SMTP_USER
user           $SMTP_USER
passwordeval   echo \$SMTP_PASS

account default : handover
EOF

export SMTP_PASS

SUBJECT="[Handover] ${HOST} | ${TS}"

# Decide attachments under 10 MiB
ATTACH_MODE="summary-only"
ATTACH_FILE=""

# We ALWAYS attach summary (very small). Additionally:
# - If full archive fits, attach it.
# - Else if light archive fits, attach that.
# - Else only summary.
if [[ "$FULL_SIZE" -gt 0 && "$FULL_SIZE" -le "$MAX_ATTACH_BYTES" ]]; then
  ATTACH_MODE="summary+full"
  ATTACH_FILE="$FULL_ARCHIVE"
elif [[ "$LIGHT_SIZE" -gt 0 && "$LIGHT_SIZE" -le "$MAX_ATTACH_BYTES" ]]; then
  ATTACH_MODE="summary+light"
  ATTACH_FILE="$LIGHT_ARCHIVE"
else
  ATTACH_MODE="summary-only"
fi

{
  echo "Server Handover Inventory"
  echo "========================="
  echo
  echo "Timestamp (UTC): $TS"
  echo "Hostname:        ${HOST:-n/a}"
  echo "FQDN:            ${FQDN:-n/a}"
  echo "IP(s):           ${IP_LIST:-n/a}"
  echo "System Serial:   ${SERIAL:-n/a}"
  echo "Board Serial:    ${BOARD_SERIAL:-n/a}"
  echo
  echo "Attachment mode: $ATTACH_MODE"
  echo "Full archive size:  $FULL_SIZE bytes"
  echo "Light archive size: $LIGHT_SIZE bytes"
  echo "Limit:              $MAX_ATTACH_BYTES bytes"
  echo
  echo "Kurz-Auszug Summary:"
  echo "--------------------"
  sed -n '1,160p' "$SUMMARY_FILE" || true
  echo
  echo "Hinweis:"
  echo "- Das vollständige Archiv wird nur angehängt, wenn es < 10 MiB ist."
  echo "- Wenn zu groß, wird ein light-Archiv (wichtigste Files) angehängt."
  echo "- Wenn auch das zu groß ist, geht nur die Summary raus."
} > "$BODY_FILE"

echo "📧 Sende Mail an $SEND_TO …"

if [[ -n "$ATTACH_FILE" ]]; then
  mail -S "sendmail=msmtp -C $MSMTP_CFG" \
       -r "$SMTP_USER" \
       -s "$SUBJECT" \
       -a "$SUMMARY_FILE" \
       -a "$ATTACH_FILE" \
       "$SEND_TO" < "$BODY_FILE"
else
  mail -S "sendmail=msmtp -C $MSMTP_CFG" \
       -r "$SMTP_USER" \
       -s "$SUBJECT" \
       -a "$SUMMARY_FILE" \
       "$SEND_TO" < "$BODY_FILE"
fi

echo "✅ Mail versendet an: $SEND_TO"
echo "🧾 msmtp log: $OUTDIR/msmtp.log"
echo "📎 Full archive:  $FULL_ARCHIVE ($FULL_SIZE bytes)"
echo "📎 Light archive: $LIGHT_ARCHIVE ($LIGHT_SIZE bytes)"
echo "📎 Attach mode:   $ATTACH_MODE"

############################################
# FINISH
############################################
log "Fertig ✅"
echo
echo "📦 Übergabeordner: $OUTDIR"
echo "📄 Zusammenfassung: $SUMMARY_FILE"
echo "📦 Full archive: $FULL_ARCHIVE"
echo "📦 Light archive: $LIGHT_ARCHIVE"
