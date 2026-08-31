#!/usr/bin/env bash
#
# Container entrypoint: runs the sniper on a loop and exits once the
# instance exists. There is no systemd in here, so the loop replaces the
# timer -- and exiting cleanly replaces "disable the timer".
#
# Every exit goes through bye(), so `docker logs` always ends with the
# reason and, when something is wrong, what to do about it. A container
# that vanishes without saying why is the thing this avoids.

set -uo pipefail

CONFIG_DIR=/etc/oracle-sniper
CONFIG_FILE="${CONFIG_DIR}/config"
KEY_FILE="${CONFIG_DIR}/api_key.pem"
STATE_DIR=/var/lib/oracle-sniper
INTERVAL="${CHECK_INTERVAL_SECONDS:-600}"

log()  { printf '[%s] %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S')" "$*"; }
line() { printf '  %s\n' "────────────────────────────────────────────────────────────"; }

# bye <exit-code> <headline> [remedy lines...]
bye() {
    local rc="$1" headline="$2"; shift 2
    printf '\n'
    line
    if [ "$rc" -eq 0 ]; then
        printf '  Stopping: %s\n' "$headline"
    else
        printf '  Stopping because of an error: %s\n' "$headline"
    fi
    if [ "$#" -gt 0 ]; then
        printf '\n  What to do:\n'
        printf '    %s\n' "$@"
    fi
    if [ "$rc" -eq 0 ]; then
        printf '\n  This exit is intentional. With "restart: on-failure" the\n'
        printf '  container stays down, which is what you want.\n'
    fi
    line
    printf '\n'
    exit "$rc"
}

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
    bye 0 "an instance was already acquired in an earlier run." \
        "Nothing, unless you want another instance." \
        "To hunt again:  docker run ... oracle-sniper resume  is not enough --" \
        "delete the marker: ${STATE_DIR}/done" \
        "Careful: a second instance beyond the free allowance is billed."
fi
if [ -f "${STATE_DIR}/paused" ]; then
    bye 0 "the sniper is paused ($(cat "${STATE_DIR}/paused" 2>/dev/null))." \
        "Run:  docker run ... oracle-sniper resume" \
        "Or delete ${STATE_DIR}/paused in the state volume."
fi

# --- Config: mounted file wins, otherwise build it from the environment ---
if [ ! -f "$CONFIG_FILE" ]; then
    missing=()
    for v in OCI_USER OCI_TENANCY OCI_FINGERPRINT OCI_REGION OCI_COMPARTMENT \
             INSTANCE_NAME SHAPE IMAGE_ID SUBNET_ID SSH_PUBLIC_KEY; do
        [ -z "${!v:-}" ] && missing+=("$v")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        bye 1 "no configuration, and required values are missing." \
            "Missing: ${missing[*]}" \
            "" \
            "Either mount a config file at ${CONFIG_FILE}" \
            "  -v /etc/oracle-sniper/config:${CONFIG_FILE}:ro" \
            "or pass the values as environment variables." \
            "" \
            "The installer writes a ready-made config:" \
            "  curl -fsSL https://raw.githubusercontent.com/brightcolor/oracle-sniper/main/install.sh | sudo bash"
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
    printf '%s' "$OCI_KEY_BASE64" | base64 -d > "$KEY_FILE" 2>/dev/null \
        || bye 1 "OCI_KEY_BASE64 is not valid base64." \
               "Encode the private key without line breaks:" \
               "  base64 -w0 < oci_api_key.pem"
    chmod 600 "$KEY_FILE"
    log "API key written from OCI_KEY_BASE64."
fi

if [ ! -r "${OCI_KEY_FILE:-$KEY_FILE}" ]; then
    bye 1 "no API signing key found." \
        "Mount the private key:" \
        "  -v /etc/oracle-sniper/api_key.pem:${KEY_FILE}:ro" \
        "or pass it as OCI_KEY_BASE64 (base64 -w0 < your_key.pem)." \
        "" \
        "This is the private half of the key registered in the OCI console" \
        "under Profile -> My profile -> API keys."
fi

# Any other argument is passed straight through: docker run ... check
if [ $# -gt 0 ]; then
    exec oracle-sniper "$@"
fi

log "Starting. Checking every ${INTERVAL}s until the instance exists."

if ! oracle-sniper check; then
    bye 1 "the configuration check failed." \
        "The output above says which part. Most often it is one of:" \
        "  - the API key is not registered in the OCI console yet" \
        "  - the fingerprint does not match the private key" \
        "  - user OCID and tenancy OCID are swapped (they look alike)" \
        "  - the region is wrong" \
        "" \
        "A freshly added key can need a minute before it authenticates." \
        "Verify without changing anything:  docker run ... oracle-sniper check"
fi

trap 'bye 0 "received a stop signal."' TERM INT

while :; do
    # Checked every round, not just at startup -- so pausing takes effect
    # without having to restart the container.
    if [ -f "${STATE_DIR}/paused" ]; then
        bye 0 "the sniper was paused while running." \
            "Run:  docker run ... oracle-sniper resume" \
            "then start the container again."
    fi

    oracle-sniper run
    rc=$?

    if [ -f "${STATE_DIR}/done" ]; then
        bye 0 "the instance was created. The hunt is over." \
            "Check the notification, or the log above, for its public IP." \
            "The marker in ${STATE_DIR}/done keeps this container from" \
            "starting another one, so leave the state volume in place."
    fi

    if [ "$rc" -ne 0 ]; then
        log "Run ended with exit ${rc}; retrying in ${INTERVAL}s."
    fi

    sleep "$INTERVAL" &
    wait $!
done
