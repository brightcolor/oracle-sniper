#!/usr/bin/env bash
#
# oracle-sniper installer
#
#   curl -fsSL https://raw.githubusercontent.com/brightcolor/oracle-sniper/main/install.sh | sudo bash
#
# Installs the sniper, walks you through the configuration and sets up the
# systemd timer. Safe to re-run: an existing config is offered for reuse.

set -uo pipefail

REPO_RAW="${ORACLE_SNIPER_REPO_RAW:-https://raw.githubusercontent.com/brightcolor/oracle-sniper/main}"
CONFIG_DIR=/etc/oracle-sniper
CONFIG_FILE="${CONFIG_DIR}/config"
LIB_DIR=/usr/local/lib/oracle-sniper
BIN=/usr/local/bin/oracle-sniper
STATE_DIR=/var/lib/oracle-sniper
UNIT_DIR=/etc/systemd/system

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
head1(){ printf '\n%s%s%s\n' "$BOLD" "$*" "$OFF"; }
ok()   { printf '%s+%s %s\n' "$GREEN" "$OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$OFF" "$*"; }
fail() { printf '%s%sx %s%s\n' "$RED" "$BOLD" "$*" "$OFF" >&2; exit 1; }

# curl | bash leaves stdin bound to the pipe, so every prompt must come
# from the terminal explicitly -- otherwise `read` eats the script itself.
TTY=/dev/tty
[ -e "$TTY" ] && [ -r "$TTY" ] || fail "No terminal available. Download install.sh and run it directly."

ask() { # ask <prompt> <default> <varname>
    local prompt="$1" default="$2" __var="$3" reply
    if [ -n "$default" ]; then
        printf '%s %s[%s]%s: ' "$prompt" "$DIM" "$default" "$OFF" > "$TTY"
    else
        printf '%s: ' "$prompt" > "$TTY"
    fi
    IFS= read -r reply < "$TTY"
    [ -z "$reply" ] && reply="$default"
    printf -v "$__var" '%s' "$reply"
}

ask_required() { # loops until non-empty
    local prompt="$1" default="$2" __var="$3"
    while :; do
        ask "$prompt" "$default" "$__var"
        [ -n "${!__var}" ] && break
        warn "This value is required."
    done
}

ask_yn() { # ask_yn <prompt> <default y|n> ; returns 0 for yes
    local prompt="$1" default="$2" reply
    printf '%s %s[%s/%s]%s: ' "$prompt" "$DIM" \
        "$([ "$default" = y ] && echo Y || echo y)" \
        "$([ "$default" = y ] && echo n || echo N)" "$OFF" > "$TTY"
    IFS= read -r reply < "$TTY"
    [ -z "$reply" ] && reply="$default"
    case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# pick <varname> <label> -- reads "value<TAB>description" lines from stdin
pick() {
    local __var="$1" label="$2" i=0 choice
    local -a vals=() descs=()
    while IFS=$'\t' read -r v d; do
        [ -z "$v" ] && continue
        vals+=("$v"); descs+=("$d")
    done
    [ ${#vals[@]} -eq 0 ] && return 1
    if [ ${#vals[@]} -eq 1 ]; then
        say "  Only one ${label} found: ${descs[0]}"
        printf -v "$__var" '%s' "${vals[0]}"; return 0
    fi
    say ""
    for i in "${!vals[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${descs[$i]}"; done
    while :; do
        ask "  Choose ${label}" "1" choice
        if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le ${#vals[@]} ]; then
            printf -v "$__var" '%s' "${vals[$((choice-1))]}"; return 0
        fi
        warn "Enter a number between 1 and ${#vals[@]}."
    done
}

# ------------------------------------------------------------ preflight ---

[ "$(id -u)" = "0" ] || fail "Please run as root (sudo)."

head1 "oracle-sniper installer"

for tool in curl openssl flock base64 systemctl; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required tool missing: $tool"
done
ok "All required tools present"

# --------------------------------------------------------------- fetch ---

install -d -m 0755 "$LIB_DIR" "$STATE_DIR"
install -d -m 0700 "$CONFIG_DIR"

fetch() { # fetch <remote-path> <target> <mode>
    local src="$2"
    if [ -f "$(dirname "$0")/$1" ] && [ "${0##*/}" = "install.sh" ]; then
        install -m "$3" "$(dirname "$0")/$1" "$src"       # local checkout
    else
        curl -fsSL "${REPO_RAW}/$1" -o "$src" || fail "Download failed: $1"
        chmod "$3" "$src"
    fi
}

fetch bin/oracle-sniper "$BIN" 0755
fetch bin/oci-api.sh "${LIB_DIR}/oci-api.sh" 0644
fetch systemd/oracle-sniper.service "${UNIT_DIR}/oracle-sniper.service" 0644
fetch systemd/oracle-sniper.timer "${UNIT_DIR}/oracle-sniper.timer" 0644
ok "Files installed"

# -------------------------------------------------------------- config ---

if [ -f "$CONFIG_FILE" ]; then
    head1 "Existing configuration found"
    say "${CONFIG_FILE} already exists."
    if ! ask_yn "Reconfigure from scratch?" n; then
        say "Keeping the existing configuration."
        # shellcheck source=/dev/null
        . "$CONFIG_FILE"
        SKIP_CONFIG=1
    fi
fi

if [ "${SKIP_CONFIG:-0}" != "1" ]; then

head1 "1. Oracle Cloud credentials"
cat <<EOF
Find these in the OCI console under Profile -> My profile -> API keys.
If you add a key there, Oracle shows a ready-made configuration snippet
containing the user OCID, tenancy OCID and fingerprint.
EOF
ask_required "  User OCID"     "${OCI_USER:-}"      OCI_USER
ask_required "  Tenancy OCID"  "${OCI_TENANCY:-}"   OCI_TENANCY
ask_required "  Region"        "${OCI_REGION:-eu-frankfurt-1}" OCI_REGION
ask          "  Compartment OCID (blank = tenancy root)" "${OCI_COMPARTMENT:-}" OCI_COMPARTMENT
[ -z "$OCI_COMPARTMENT" ] && OCI_COMPARTMENT="$OCI_TENANCY"

head1 "2. API signing key"
KEY_FILE="${CONFIG_DIR}/api_key.pem"
if [ -f "$KEY_FILE" ] && ask_yn "  Reuse the existing key at ${KEY_FILE}?" y; then
    :
else
    ask "  Path to an existing private key (blank = generate a new one)" "" EXISTING_KEY
    if [ -n "$EXISTING_KEY" ]; then
        [ -r "$EXISTING_KEY" ] || fail "Cannot read $EXISTING_KEY"
        install -m 0600 "$EXISTING_KEY" "$KEY_FILE"
    else
        openssl genrsa -out "$KEY_FILE" 2048 2>/dev/null || fail "Key generation failed"
        chmod 600 "$KEY_FILE"
        ok "New key generated"
    fi
fi
FINGERPRINT="$(openssl rsa -pubout -outform DER -in "$KEY_FILE" 2>/dev/null | openssl md5 -c | sed 's/^.*= //')"
say ""
say "  Fingerprint: ${BOLD}${FINGERPRINT}${OFF}"
say ""
say "  This public key must be registered in your OCI profile."
say "  If you have not done that yet, paste the block below into"
say "  Profile -> My profile -> API keys -> Add API key -> Paste a public key:"
say ""
openssl rsa -pubout -in "$KEY_FILE" 2>/dev/null | sed 's/^/    /'
say ""
ask "  Press Enter once the key is registered" "" _

head1 "3. Verifying API access"
export OCI_USER OCI_TENANCY OCI_FINGERPRINT="$FINGERPRINT" OCI_REGION OCI_KEY_FILE="$KEY_FILE"
# shellcheck source=/dev/null
. "${LIB_DIR}/oci-api.sh"
IAAS_HOST="$(oci_host iaas)"; IDENTITY_HOST="$(oci_host identity)"

AD_LIST="$(oci_get "$IDENTITY_HOST" "/20160918/availabilityDomains?compartmentId=${OCI_COMPARTMENT}" \
            | tr ',' '\n' | grep -o '"name":"[^"]*"' | cut -d'"' -f4)"
if [ -z "$AD_LIST" ]; then
    fail "API call failed. Check the OCIDs, the region and that the key is registered.
Note that new keys can take a minute to become active."
fi
ok "API access works"
say "  Availability domains:"; printf '    %s\n' $AD_LIST

head1 "4. Network"
SUBNET_ID=""
oci_get "$IAAS_HOST" "/20160918/subnets?compartmentId=${OCI_COMPARTMENT}" \
    | tr '{' '\n' \
    | while IFS= read -r line; do
        id="$(printf '%s' "$line" | grep -o '"id":"ocid1.subnet[^"]*"' | cut -d'"' -f4)"
        [ -z "$id" ] && continue
        name="$(printf '%s' "$line" | grep -o '"displayName":"[^"]*"' | cut -d'"' -f4)"
        cidr="$(printf '%s' "$line" | grep -o '"cidrBlock":"[^"]*"' | cut -d'"' -f4)"
        priv="$(printf '%s' "$line" | grep -o '"prohibitPublicIpOnVnic":[a-z]*' | cut -d: -f2)"
        vis="public"; [ "$priv" = "true" ] && vis="private"
        printf '%s\t%s (%s, %s)\n' "$id" "$name" "$cidr" "$vis"
      done > /tmp/.sniper-subnets
pick SUBNET_ID "subnet" < /tmp/.sniper-subnets || fail "No subnets found. Create a VCN first."
rm -f /tmp/.sniper-subnets
ASSIGN_PUBLIC_IP=true
ask_yn "  Assign a public IP?" y || ASSIGN_PUBLIC_IP=false

head1 "5. Instance shape"
say "  Always Free options: VM.Standard.A1.Flex (Arm, 2 OCPU / 12 GB total)"
say "                       VM.Standard.E2.1.Micro (AMD, 1/8 OCPU / 1 GB)"
ask "  Shape" "${SHAPE:-VM.Standard.A1.Flex}" SHAPE
OCPUS=""; MEMORY_GB=""
if printf '%s' "$SHAPE" | grep -qi 'flex'; then
    ask "  OCPUs" "${OCPUS:-2}" OCPUS
    ask "  Memory in GB" "${MEMORY_GB:-12}" MEMORY_GB
fi
ask "  Boot volume size in GB" "${BOOT_VOLUME_GB:-50}" BOOT_VOLUME_GB
ask "  Instance name" "${INSTANCE_NAME:-free-instance}" INSTANCE_NAME

head1 "6. Operating system image"
ask "  Operating system" "Canonical Ubuntu" IMAGE_OS
ask "  Version" "24.04" IMAGE_VER
OS_ENC="$(printf '%s' "$IMAGE_OS" | sed 's/ /%20/g')"
oci_get "$IAAS_HOST" "/20160918/images?compartmentId=${OCI_COMPARTMENT}&operatingSystem=${OS_ENC}&operatingSystemVersion=${IMAGE_VER}&shape=${SHAPE}&sortBy=TIMECREATED&sortOrder=DESC&limit=8" \
    | tr '{' '\n' \
    | while IFS= read -r line; do
        id="$(printf '%s' "$line" | grep -o '"id":"ocid1.image[^"]*"' | cut -d'"' -f4)"
        [ -z "$id" ] && continue
        name="$(printf '%s' "$line" | grep -o '"displayName":"[^"]*"' | cut -d'"' -f4)"
        printf '%s\t%s\n' "$id" "$name"
      done > /tmp/.sniper-images
IMAGE_ID=""
pick IMAGE_ID "image" < /tmp/.sniper-images \
    || fail "No image found for ${IMAGE_OS} ${IMAGE_VER} on ${SHAPE}. Check the spelling."
rm -f /tmp/.sniper-images

head1 "7. SSH access"
say "  The public key that gets installed for the default user."
SSH_PUBLIC_KEY=""
while [ -z "$SSH_PUBLIC_KEY" ]; do
    ask "  Path to a public key file, or paste the key itself" "${HOME}/.ssh/id_ed25519.pub" SSH_IN
    if [ -r "$SSH_IN" ]; then
        SSH_PUBLIC_KEY="$(cat "$SSH_IN")"
    elif printf '%s' "$SSH_IN" | grep -q '^\(ssh-\|ecdsa-\)'; then
        SSH_PUBLIC_KEY="$SSH_IN"
    else
        warn "Not a readable file and not a public key. Try again."
    fi
done
ok "Key accepted ($(printf '%s' "$SSH_PUBLIC_KEY" | awk '{print $1}'))"
ask "  Default login user of that image" "${SSH_USER:-ubuntu}" SSH_USER

head1 "8. Notifications (optional)"
say "  Leave blank to skip. Without any channel, results only reach the journal."
ask "  Pushover application token" "${NOTIFY_PUSHOVER_TOKEN:-}" NOTIFY_PUSHOVER_TOKEN
[ -n "$NOTIFY_PUSHOVER_TOKEN" ] && ask "  Pushover user key" "${NOTIFY_PUSHOVER_USER:-}" NOTIFY_PUSHOVER_USER
ask "  ntfy topic URL (e.g. https://ntfy.sh/my-secret-topic)" "${NOTIFY_NTFY_URL:-}" NOTIFY_NTFY_URL
ask "  Generic webhook URL" "${NOTIFY_WEBHOOK_URL:-}" NOTIFY_WEBHOOK_URL

head1 "9. Schedule"
say "  Oracle rate-limits aggressive polling. Ten minutes is a good default."
ask "  Interval between attempts" "${CHECK_INTERVAL:-10min}" CHECK_INTERVAL

# ------------------------------------------------------------- write it ---

umask 077
cat > "$CONFIG_FILE" <<EOF
# oracle-sniper configuration
# Written by the installer on $(date -u +'%Y-%m-%d %H:%M:%S') UTC.
# Edit freely, then run: systemctl restart oracle-sniper.timer

# --- Oracle Cloud API credentials ---
OCI_USER=${OCI_USER}
OCI_TENANCY=${OCI_TENANCY}
OCI_FINGERPRINT=${FINGERPRINT}
OCI_REGION=${OCI_REGION}
OCI_COMPARTMENT=${OCI_COMPARTMENT}
OCI_KEY_FILE=${KEY_FILE}

# --- What to create ---
INSTANCE_NAME=${INSTANCE_NAME}
SHAPE=${SHAPE}
OCPUS=${OCPUS}
MEMORY_GB=${MEMORY_GB}
BOOT_VOLUME_GB=${BOOT_VOLUME_GB}
IMAGE_ID=${IMAGE_ID}
SUBNET_ID=${SUBNET_ID}
ASSIGN_PUBLIC_IP=${ASSIGN_PUBLIC_IP}

# Public key installed for the default user, and that user's name.
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY}"
SSH_USER=${SSH_USER}

# Optional cloud-init file, applied at first boot.
CLOUD_INIT_FILE=

# Availability domains to try, space separated.
# Leave empty to discover and cache them automatically.
AVAILABILITY_DOMAINS=

# Disable the timer once the instance exists. Keep this on unless you
# really want it to keep running -- extra instances are not free.
STOP_WHEN_DONE=true

# --- Notifications ---
NOTIFY_PUSHOVER_TOKEN=${NOTIFY_PUSHOVER_TOKEN}
NOTIFY_PUSHOVER_USER=${NOTIFY_PUSHOVER_USER:-}
NOTIFY_NTFY_URL=${NOTIFY_NTFY_URL}
NOTIFY_WEBHOOK_URL=${NOTIFY_WEBHOOK_URL}
EOF
chmod 600 "$CONFIG_FILE"
ok "Configuration written to ${CONFIG_FILE}"

sed -i "s|^OnUnitActiveSec=.*|OnUnitActiveSec=${CHECK_INTERVAL}|" "${UNIT_DIR}/oracle-sniper.timer"

fi  # SKIP_CONFIG

# --------------------------------------------------------------- finish ---

systemctl daemon-reload
ok "systemd units registered"

head1 "Checking the setup"
"$BIN" check || fail "Configuration check failed. Fix ${CONFIG_FILE} and re-run: oracle-sniper check"

if [ -n "${NOTIFY_PUSHOVER_TOKEN:-}${NOTIFY_NTFY_URL:-}${NOTIFY_WEBHOOK_URL:-}" ]; then
    if ask_yn $'\nSend a test notification?' y; then
        "$BIN" test-notify
    fi
fi

head1 "Ready"
if ask_yn "Start hunting now?" y; then
    systemctl enable --now oracle-sniper.timer
    ok "Timer active"
    systemctl list-timers oracle-sniper.timer --no-pager | head -3
else
    say "Start it later with: systemctl enable --now oracle-sniper.timer"
fi

cat <<EOF

  oracle-sniper status        what is going on
  oracle-sniper run           try once, right now
  oracle-sniper check         verify config and API access
  journalctl -u oracle-sniper.service -f    follow attempts live

  Config: ${CONFIG_FILE}

EOF
