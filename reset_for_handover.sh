#!/usr/bin/env bash
set -euo pipefail

# ==============================
# DANGER ZONE - HANDOVER RESET
# Ubuntu 20.04
#
# - Deletes all non-system users (UID>=1000) except: root, thiegmbh
# - Removes their home dirs (-r)
# - Wipes docker containers/images/volumes/networks (prune)
# - Resets SSH to Port 22, enables password login, enables root login
# - Creates user "thiegmbh" with sudo rights and sets a password
#
# REQUIREMENTS:
#   Run as root (sudo).
#   Keep an existing SSH session open (failsafe) or use console access.
# ==============================

# ---- Safety brake ----
: "${CONFIRM:=NO}"
if [[ "${CONFIRM}" != "YES" ]]; then
  echo "❌ Refusing to run. This will DELETE users/data and weaken SSH security."
  echo "To run: sudo CONFIRM=YES $0"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "❌ Please run as root: sudo CONFIRM=YES $0"
  exit 1
fi

TS="$(date -u +"%Y-%m-%dT%H%M%SZ")"
LOG="/root/handover_reset_${TS}.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== HANDOVER RESET START @ ${TS} ==="
echo "Log: $LOG"

# ------------------------------
# Helper
# ------------------------------
backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak_${TS}"
    echo "Backup: $f -> ${f}.bak_${TS}"
  fi
}

# ------------------------------
# 1) Ensure user thiegmbh exists + sudo
# ------------------------------
TARGET_USER="thiegmbh"

if id "$TARGET_USER" >/dev/null 2>&1; then
  echo "User $TARGET_USER already exists."
else
  echo "Creating user: $TARGET_USER"
  adduser --gecos "" "$TARGET_USER"
fi

echo "Adding $TARGET_USER to sudo group"
usermod -aG sudo "$TARGET_USER"

echo "Setting password for $TARGET_USER (interactive)"
passwd "$TARGET_USER"

# ------------------------------
# 2) Docker CLEAN SHUTDOWN + WIPE
# ------------------------------
if command -v docker >/dev/null 2>&1; then
  echo "Docker found. Performing CLEAN shutdown of all containers..."

  # 1) List running containers
  RUNNING_CONTAINERS=$(docker ps -q)

  if [[ -n "$RUNNING_CONTAINERS" ]]; then
    echo "Stopping running containers (graceful, timeout=30s)..."

    # 2) Graceful stop (SIGTERM, wait)
    docker stop -t 30 $RUNNING_CONTAINERS

    # 3) Wait until all containers are really stopped
    echo "Waiting for containers to fully stop..."
    for i in {1..30}; do
      STILL_RUNNING=$(docker ps -q)
      if [[ -z "$STILL_RUNNING" ]]; then
        echo "All containers stopped."
        break
      fi
      sleep 1
    done

    # Safety check
    if [[ -n "$(docker ps -q)" ]]; then
      echo "⚠ Some containers did not stop gracefully – forcing stop"
      docker ps -q | xargs -r docker kill
    fi
  else
    echo "No running containers found."
  fi

  # 4) Remove containers
  echo "Removing all containers..."
  docker ps -a -q | xargs -r docker rm -f

  # 5) Remove images
  echo "Removing all images..."
  docker images -q | sort -u | xargs -r docker rmi -f

  # 6) Remove volumes
  echo "Removing all volumes..."
  docker volume ls -q | xargs -r docker volume rm -f

  # 7) Remove networks (except default)
  echo "Removing custom docker networks..."
  docker network ls --format '{{.Name}}' \
    | grep -vE '^(bridge|host|none)$' \
    | xargs -r docker network rm

  # 8) Final prune (safety)
  docker system prune -af --volumes

  # 9) Optional: stop docker daemon cleanly
  echo "Stopping docker service..."
  systemctl stop docker
  systemctl stop containerd || true

  echo "Docker clean shutdown & wipe completed."
else
  echo "Docker not installed. Skipping docker cleanup."
fi


# ------------------------------
# 3) Delete all non-system users except root + thiegmbh
#    Ubuntu: typically UID>=1000 are human users.
# ------------------------------
echo "Deleting non-system users (UID>=1000) except root + ${TARGET_USER}..."

# Build list of candidate users
mapfile -t USERS < <(awk -F: '($3>=1000)&&($1!="nobody") {print $1":"$3":"$6}' /etc/passwd)

for entry in "${USERS[@]}"; do
  u="${entry%%:*}"
  rest="${entry#*:}"
  uid="${rest%%:*}"
  home="${entry##*:}"

  # Exclusions
  if [[ "$u" == "root" || "$u" == "$TARGET_USER" ]]; then
    echo "Skipping user: $u"
    continue
  fi

  echo "-> Removing user: $u (uid=$uid, home=$home)"

  # Best-effort: kill processes
  pkill -KILL -u "$u" >/dev/null 2>&1 || true

  # Remove crontab
  crontab -u "$u" -r >/dev/null 2>&1 || true

  # Delete user + home
  userdel -r "$u" >/dev/null 2>&1 || {
    echo "userdel -r failed for $u, trying without -r then remove home..."
    userdel "$u" >/dev/null 2>&1 || true
    if [[ -d "$home" && "$home" == /home/* ]]; then
      rm -rf "$home"
    fi
  }
done

echo "User deletion completed."

# ------------------------------
# 4) Reset SSH settings:
#    - Port 22
#    - PasswordAuthentication yes
#    - PermitRootLogin yes
#    - PubkeyAuthentication yes (allowed, but password must work)
# ------------------------------
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"

echo "Resetting SSH configuration..."
backup_file "$SSHD_CONFIG"

# Also backup any drop-ins (common cause of "why doesn't it change")
if [[ -d "$SSHD_DROPIN_DIR" ]]; then
  tar -czf "/root/sshd_config_d_backup_${TS}.tar.gz" "$SSHD_DROPIN_DIR" >/dev/null 2>&1 || true
  echo "Backup: $SSHD_DROPIN_DIR -> /root/sshd_config_d_backup_${TS}.tar.gz"
fi

# Remove conflicting lines in main config (best-effort)
# then append our desired settings at the end to override earlier entries.
sed -i \
  -e '/^\s*Port\s\+/Id' \
  -e '/^\s*PasswordAuthentication\s\+/Id' \
  -e '/^\s*PermitRootLogin\s\+/Id' \
  -e '/^\s*PubkeyAuthentication\s\+/Id' \
  -e '/^\s*KbdInteractiveAuthentication\s\+/Id' \
  -e '/^\s*ChallengeResponseAuthentication\s\+/Id' \
  -e '/^\s*UsePAM\s\+/Id' \
  "$SSHD_CONFIG"

cat >> "$SSHD_CONFIG" <<'EOF'

# --- HANDOVER RESET OVERRIDES ---
Port 22
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
# --- END HANDOVER RESET OVERRIDES ---
EOF

# If there are drop-ins that might override, we add a high-priority drop-in.
mkdir -p "$SSHD_DROPIN_DIR"
DROPIN="$SSHD_DROPIN_DIR/99-handover-reset.conf"
backup_file "$DROPIN"
cat > "$DROPIN" <<'EOF'
# --- HANDOVER RESET DROP-IN (highest priority) ---
Port 22
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
# --- END ---
EOF

echo "Validating sshd config..."
sshd -t

# ------------------------------
# 5) Firewall adjustment (UFW)
# ------------------------------
if command -v ufw >/dev/null 2>&1; then
  UFW_STATUS="$(ufw status 2>/dev/null | head -n 1 || true)"
  echo "UFW status: $UFW_STATUS"
  if echo "$UFW_STATUS" | grep -qi "active"; then
    echo "Allowing SSH on 22/tcp (ufw)"
    ufw allow 22/tcp >/dev/null 2>&1 || true

    # If 12128 was used, remove allow rule (best-effort; may not exist)
    ufw delete allow 12128/tcp >/dev/null 2>&1 || true
    ufw delete allow 12128 >/dev/null 2>&1 || true
  else
    echo "UFW not active. Skipping firewall changes."
  fi
else
  echo "UFW not installed. Skipping firewall changes."
fi

# ------------------------------
# 6) Restart SSH service safely
# ------------------------------
echo "Restarting SSH service..."
systemctl restart ssh || systemctl restart sshd

echo
echo "=== DONE ✅ ==="
echo "Summary:"
echo " - Created/ensured user: ${TARGET_USER} (sudo) + password set"
echo " - Deleted non-system users (UID>=1000) except ${TARGET_USER}"
echo " - Docker wiped (if installed)"
echo " - SSH set to Port 22, password login enabled, root login enabled"
echo
echo "IMPORTANT:"
echo " - Keep your current SSH session open and TEST a NEW login on port 22 before closing."
echo " - This SSH configuration is INSECURE by design (password + root login). Re-harden after handover."
echo
echo "Log saved to: $LOG"
