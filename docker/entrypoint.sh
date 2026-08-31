#!/usr/bin/env bash
#
# Container entrypoint: runs the sniper on a loop and exits once the
# instance exists. There is no systemd in here, so the loop replaces the
# timer -- and exiting cleanly replaces "disable the timer".

set -uo pipefail

CONFIG_DIR=/etc/oracle-sniper
CONFIG_FILE="${CONFIG_DIR}/config"
KEY_FILE="${CONFIG_DIR}/api_key.pem"
STATE_DIR=/var/lib/oracle-sniper
INTERVAL="${CHECK_INTERVAL_SECONDS:-600}"

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S')" "$*"; }

mkdir -p "$CONFIG_DIR" "$STATE_DIR"

# These need neither configuration nor an unpaused state -- and `resume`
# in particular must work while paused, or there is no way back out.
case "${1:-}" in
    pause|resume|version|help|-h|--help) exec oracle-sniper "$@" ;;
esac

# --- Brakes ---------------------------------------------------------------
# Both files live in the state volume, so they survive restarts, recreated
# containers and rebuilt images. Checked before the configuration: a stopped
# sniper should stay quiet rather than complain about settings it is not
# going to use.
if [ -f "${STATE_DIR}/done" ]; then
    log "Instance was already acquired in an earlier run. Nothing to do."
    log "Delete ${STATE_DIR}/done to hunt again."
    exit 0
fi
if [ -f "${STATE_DIR}/paused" ]; then
    log "Paused: $(cat "${STATE_DIR}/paused" 2>/dev/null)"
    log "Delete ${STATE_DIR}/paused, or run 'oracle-sniper resume', to continue."
    exit 0
fi

# --- Config: mounted file wins, otherwise build it from the environment ---
if [ ! -f "$CONFIG_FILE" ]; then
    missing=()
    for v in OCI_USER OCI_TENANCY OCI_FINGERPRINT OCI_REGION OCI_COMPARTMENT \
             INSTANCE_NAME SHAPE IMAGE_ID SUBNET_ID SSH_PUBLIC_KEY; do
        [ -z "${!v:-}" ] && missing+=("$v")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log "No config at ${CONFIG_FILE}, and these variables are missing:"
        printf '        %s\n' "${missing[*]}"
        log "Either mount a config file at ${CONFIG_FILE} or pass the variables."
        exit 1
    fi

    umask 077
    cat > "$CONFIG_FILE" <<EOF
OCI_USER=${OCI_USER}
OCI_TENANCY=${OCI_TENANCY}
OCI_FINGERPRINT=${OCI_FINGERPRINT}
OCI_REGION=${OCI_REGION}
OCI_COMPARTMENT=${OCI_COMPARTMENT}
OCI_KEY_FILE=${OCI_KEY_FILE:-$KEY_FILE}

INSTANCE_NAME=${INSTANCE_NAME}
SHAPE=${SHAPE}
OCPUS=${OCPUS:-}
MEMORY_GB=${MEMORY_GB:-}
BOOT_VOLUME_GB=${BOOT_VOLUME_GB:-50}
IMAGE_ID=${IMAGE_ID}
SUBNET_ID=${SUBNET_ID}
ASSIGN_PUBLIC_IP=${ASSIGN_PUBLIC_IP:-true}
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY}"
SSH_USER=${SSH_USER:-ubuntu}
CLOUD_INIT_FILE=${CLOUD_INIT_FILE:-}
AVAILABILITY_DOMAINS=${AVAILABILITY_DOMAINS:-}
STOP_WHEN_DONE=${STOP_WHEN_DONE:-true}

NOTIFY_PUSHOVER_TOKEN=${NOTIFY_PUSHOVER_TOKEN:-}
NOTIFY_PUSHOVER_USER=${NOTIFY_PUSHOVER_USER:-}
NOTIFY_NTFY_URL=${NOTIFY_NTFY_URL:-}
NOTIFY_WEBHOOK_URL=${NOTIFY_WEBHOOK_URL:-}
EOF
    chmod 600 "$CONFIG_FILE"
    log "Config written from environment variables."
fi

# --- API key: mounted file, or handed over base64-encoded ---------------
if [ ! -f "$KEY_FILE" ] && [ -n "${OCI_KEY_BASE64:-}" ]; then
    printf '%s' "$OCI_KEY_BASE64" | base64 -d > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    log "API key written from OCI_KEY_BASE64."
fi

if [ ! -r "${OCI_KEY_FILE:-$KEY_FILE}" ]; then
    log "No API key found. Mount one at ${KEY_FILE} or pass OCI_KEY_BASE64."
    exit 1
fi

# Any argument is passed straight through: docker run ... check
if [ $# -gt 0 ]; then
    exec oracle-sniper "$@"
fi

log "Starting. Checking every ${INTERVAL}s until the instance exists."
oracle-sniper check || { log "Configuration check failed."; exit 1; }

trap 'log "Stopping."; exit 0' TERM INT

while :; do
    # Checked every round, not just at startup -- so pausing takes effect
    # without having to restart the container.
    if [ -f "${STATE_DIR}/paused" ]; then
        log "Paused. Exiting; remove the marker and start the container again."
        exit 0
    fi

    oracle-sniper run

    if [ -f "${STATE_DIR}/done" ]; then
        log "Done. Exiting so the container is not restarted."
        exit 0
    fi
    sleep "$INTERVAL" &
    wait $!
done
