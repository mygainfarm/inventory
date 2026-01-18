#!/usr/bin/env bash
set -euo pipefail

############################################
# CONFIG
############################################
REQUIRED_CMDS=(
  lscpu free lsblk lspci lshw dmidecode smartctl nvme nvidia-smi jq
)

APT_PACKAGES=(
  pciutils
  lshw
  dmidecode
  smartmontools
  nvme-cli
  jq
  util-linux
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
HOST="$(hostname -s)"
OUTDIR="handover_${HOST}_${TS}"
mkdir -p "$OUTDIR"

log() {
  echo "➡ $1"
}

run() {
  local cmd="$1"
  local file="$2"
  {
    echo "### CMD: $cmd"
    echo
    eval "$cmd"
  } > "$OUTDIR/$file" 2> "$OUTDIR/${file}.err" || true
}

############################################
# DATA COLLECTION
############################################
log "System"
run 'hostname; hostname -f; uname -a; uptime -p; cat /etc/os-release' "00_system.txt"

log "CPU"
run 'lscpu' "10_cpu.txt"

log "RAM"
run 'free -h; echo; dmidecode -t memory' "20_ram.txt"

log "GPUs"
if command -v nvidia-smi >/dev/null; then
  run 'nvidia-smi' "30_gpu_overview.txt"
  run 'nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,serial,driver_version,vbios_version,memory.total --format=csv' "31_gpu_details.csv"
else
  echo "nvidia-smi nicht verfügbar" > "$OUTDIR/30_gpu_overview.txt"
fi

log "PCI"
run 'lspci -nn | sort' "40_pci.txt"

log "Storage"
run 'lsblk -o NAME,MODEL,SERIAL,SIZE,TYPE,ROTA,TRAN,MOUNTPOINT -e7' "50_storage_lsblk.txt"
run 'blkid' "51_storage_blkid.txt"
run 'df -hT' "52_storage_df.txt"
run 'nvme list' "53_nvme_list.txt"
run 'for d in /dev/nvme*n1; do nvme id-ctrl "$d"; done' "54_nvme_details.txt"

log "SMART"
run 'for d in /dev/sd? /dev/nvme?n1; do smartctl -H -i "$d"; echo; done' "55_smart.txt"

log "Network"
run 'ip -br a; ip r' "60_network.txt"
run 'lshw -class network -short' "61_network_hw.txt"

log "System Serials"
run 'dmidecode -t system -t baseboard -t chassis' "70_serials.txt"

############################################
# SUMMARY (ÜBERGABESEITE)
############################################
log "Erstelle Zusammenfassung"

CPU_MODEL=$(lscpu | awk -F: '/Model name/ {print $2}' | xargs)
CPU_SOCKETS=$(lscpu | awk -F: '/Socket\(s\)/ {print $2}' | xargs)
CPU_CORES=$(lscpu | awk -F: '/Core\(s\) per socket/ {print $2}' | xargs)
CPU_THREADS=$(lscpu | awk -F: '/Thread\(s\) per core/ {print $2}' | xargs)

RAM_TOTAL=$(free -h | awk '/Mem:/ {print $2}')

GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l || echo 0)
GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort | uniq)

NVME_TOTAL=$(lsblk -d -b -o SIZE,TYPE | awk '$2=="disk"{s+=$1} END {printf "%.2f TB", s/1024/1024/1024/1024}')

{
echo "=============================="
echo "SERVER ÜBERGABE – HARDWARE"
echo "=============================="
echo
echo "Host:            $HOST"
echo "Timestamp (UTC): $TS"
echo
echo "CPU:"
echo "  Modell:        $CPU_MODEL"
echo "  Sockets:       $CPU_SOCKETS"
echo "  Cores/Socket:  $CPU_CORES"
echo "  Threads/Core:  $CPU_THREADS"
echo
echo "RAM:"
echo "  Gesamt:        $RAM_TOTAL"
echo
echo "GPU:"
echo "  Anzahl:        $GPU_COUNT"
echo "  Modell(e):"
echo "$GPU_MODEL" | sed 's/^/    - /'
echo
echo "Storage:"
echo "  Gesamt Rohkapazität: $NVME_TOTAL"
echo
echo "OS:"
grep PRETTY_NAME /etc/os-release | cut -d= -f2
echo
echo "Details siehe Einzelreports im Ordner:"
echo "  $OUTDIR/"
} > "$OUTDIR/ZZ_ÜBERGABE_ZUSAMMENFASSUNG.txt"

############################################
# FINISH
############################################
log "Fertig ✅"
echo
echo "📦 Übergabeordner: $OUTDIR"
echo "📄 Zusammenfassung: ZZ_ÜBERGABE_ZUSAMMENFASSUNG.txt"
echo
echo "Empfohlen:"
echo "tar -czf ${OUTDIR}.tar.gz ${OUTDIR}"
