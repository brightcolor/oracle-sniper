#!/usr/bin/env bash
#
# oracle-sniper installer / uninstaller
#
#   curl -fsSL https://raw.githubusercontent.com/brightcolor/oracle-sniper/main/install.sh | sudo bash
#
# Installs either as a systemd timer or as a Docker container, checks the
# prerequisites for whichever you pick, and offers to remove everything
# again when run a second time.

set -uo pipefail

VERSION="1.3.0"
REPO_RAW="${ORACLE_SNIPER_REPO_RAW:-https://raw.githubusercontent.com/brightcolor/oracle-sniper/main}"
IMAGE="${ORACLE_SNIPER_IMAGE:-ghcr.io/brightcolor/oracle-sniper:latest}"

CONFIG_DIR=/etc/oracle-sniper
CONFIG_FILE="${CONFIG_DIR}/config"
KEY_FILE="${CONFIG_DIR}/api_key.pem"
LIB_DIR=/usr/local/lib/oracle-sniper
BIN=/usr/local/bin/oracle-sniper
STATE_DIR=/var/lib/oracle-sniper
UNIT_DIR=/etc/systemd/system
DOCKER_DIR=/opt/oracle-sniper

B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'

say()   { printf '%s\n' "$*"; }
rule()  { printf '%s%s%s\n' "$D" "────────────────────────────────────────────────────────" "$N"; }
head1() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
ok()    { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
info()  { printf '  %s·%s %s\n' "$D" "$N" "$*"; }
fail()  { printf '\n%s%s✗ %s%s\n\n' "$R" "$B" "$*" "$N" >&2; exit 1; }

banner() {
    printf '\n%s  oracle-sniper%s %s%s%s\n' "$B" "$N" "$D" "$VERSION" "$N"
    printf '  %skeeps asking Oracle Cloud until an Always Free instance is yours%s\n' "$D" "$N"
    rule
}

# curl | bash leaves stdin bound to the pipe, so prompts must come from
# the terminal explicitly -- otherwise `read` swallows the script itself.
TTY=/dev/tty
[ -e "$TTY" ] && [ -r "$TTY" ] || fail "No terminal available. Download install.sh and run it directly."

ask() {
    local prompt="$1" default="$2" __var="$3" reply
    if [ -n "$default" ]; then
        printf '  %s %s[%s]%s ' "$prompt" "$D" "$default" "$N" > "$TTY"
    else
        printf '  %s ' "$prompt" > "$TTY"
    fi
    IFS= read -r reply < "$TTY"
    [ -z "$reply" ] && reply="$default"
    printf -v "$__var" '%s' "$reply"
}

ask_required() {
    local prompt="$1" default="$2" __var="$3"
    while :; do
        ask "$prompt" "$default" "$__var"
        [ -n "${!__var}" ] && break
        warn "Required."
    done
}

ask_yn() {
    local prompt="$1" default="$2" reply
    printf '  %s %s[%s]%s ' "$prompt" "$D" \
        "$([ "$default" = y ] && echo 'Y/n' || echo 'y/N')" "$N" > "$TTY"
    IFS= read -r reply < "$TTY"
    [ -z "$reply" ] && reply="$default"
    case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# menu <varname> <prompt> <label>... -- sets varname to the chosen index
menu() {
    local __var="$1" prompt="$2"; shift 2
    local -a items=("$@") choice i
    say ""
    for i in "${!items[@]}"; do printf '   %s%d)%s %s\n' "$B" "$((i+1))" "$N" "${items[$i]}"; done
    say ""
    while :; do
        ask "$prompt" "1" choice
        if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le ${#items[@]} ]; then
            printf -v "$__var" '%s' "$choice"; return 0
        fi
        warn "Enter a number between 1 and ${#items[@]}."
    done
}

pick() {
    local __var="$1" label="$2" i=0 choice
    local -a vals=() descs=()
    while IFS=$'\t' read -r v d; do
        [ -z "$v" ] && continue
        vals+=("$v"); descs+=("$d")
    done
    [ ${#vals[@]} -eq 0 ] && return 1
    if [ ${#vals[@]} -eq 1 ]; then
        info "Only one ${label}: ${descs[0]}"
        printf -v "$__var" '%s' "${vals[0]}"; return 0
    fi
    say ""
    for i in "${!vals[@]}"; do printf '   %s%2d)%s %s\n' "$B" "$((i+1))" "$N" "${descs[$i]}"; done
    say ""
    while :; do
        ask "Choose ${label}:" "1" choice
        if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le ${#vals[@]} ]; then
            printf -v "$__var" '%s' "${vals[$((choice-1))]}"; return 0
        fi
        warn "Enter a number between 1 and ${#vals[@]}."
    done
}

# ------------------------------------------------------------- detection ---

INSTALLED_MODE=""      # systemd | docker | ""
detect_install() {
    if [ -f "${UNIT_DIR}/oracle-sniper.service" ] || [ -f "$BIN" ]; then
        INSTALLED_MODE="systemd"
    fi
    if [ -f "${DOCKER_DIR}/docker-compose.yml" ] \
       || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx oracle-sniper; then
        INSTALLED_MODE="${INSTALLED_MODE:+both}"
        [ -z "$INSTALLED_MODE" ] && INSTALLED_MODE="docker"
    fi
}

# ----------------------------------------------------------- requirements ---

have() { command -v "$1" >/dev/null 2>&1; }

install_docker_engine() {
    head1 "Installing Docker"
    say "  Using the official convenience script from get.docker.com."
    ask_yn "Proceed?" y || fail "Cancelled."
    curl -fsSL https://get.docker.com | sh || fail "Docker installation failed."
    systemctl enable --now docker >/dev/null 2>&1 || true
    have docker || fail "Docker still not available after installation."
    ok "Docker installed"
}

check_requirements() {
    local mode="$1" missing=() pkg_missing=()
    head1 "Checking prerequisites"

    if [ "$mode" = "docker" ]; then
        if have docker; then
            ok "docker $(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//')"
        else
            warn "docker is not installed"
            missing+=(docker)
        fi
        if have docker && docker compose version >/dev/null 2>&1; then
            ok "docker compose plugin"
        elif have docker; then
            warn "docker compose plugin missing"
            missing+=(compose)
        fi
        have curl && ok "curl" || pkg_missing+=(curl)
        have openssl && ok "openssl" || pkg_missing+=(openssl)
    else
        for t in bash curl openssl flock base64; do
            have "$t" && ok "$t" || { warn "$t missing"; pkg_missing+=("$t"); }
        done
        if have systemctl; then
            ok "systemd"
        else
            fail "systemd not found. Use the Docker mode instead."
        fi
    fi

    if [ ${#pkg_missing[@]} -gt 0 ]; then
        say ""
        warn "Missing tools: ${pkg_missing[*]}"
        if ask_yn "Install them now?" y; then
            if have apt-get;   then apt-get update -qq && apt-get install -y "${pkg_missing[@]}"
            elif have dnf;     then dnf install -y "${pkg_missing[@]}"
            elif have yum;     then yum install -y "${pkg_missing[@]}"
            elif have apk;     then apk add --no-cache "${pkg_missing[@]}"
            elif have pacman;  then pacman -Sy --noconfirm "${pkg_missing[@]}"
            else fail "Unknown package manager. Install manually: ${pkg_missing[*]}"
            fi
            ok "Installed"
        else
            fail "Cannot continue without: ${pkg_missing[*]}"
        fi
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        say ""
        if printf '%s\n' "${missing[@]}" | grep -qx docker; then
            if ask_yn "Docker is required. Install it now?" y; then
                install_docker_engine
            else
                fail "Cancelled. Install Docker, or re-run and choose the systemd mode."
            fi
        fi
        if printf '%s\n' "${missing[@]}" | grep -qx compose; then
            fail "The docker compose plugin is missing. Install docker-compose-plugin and re-run."
        fi
    fi
}

# ------------------------------------------------------------- uninstall ---

do_uninstall() {
    head1 "Uninstall"
    say "  Found an existing installation (${INSTALLED_MODE})."
    say ""
    say "  This removes the program, the systemd units and/or the container."
    say "  Your Oracle Cloud instance is ${B}not${N} touched."
    say ""
    ask_yn "Continue?" n || { say ""; info "Nothing changed."; exit 0; }

    # systemd side
    if [ -f "${UNIT_DIR}/oracle-sniper.service" ] || [ -f "$BIN" ]; then
        systemctl disable --now oracle-sniper.timer   >/dev/null 2>&1
        systemctl disable --now oracle-sniper.service >/dev/null 2>&1
        rm -f "${UNIT_DIR}/oracle-sniper.service" "${UNIT_DIR}/oracle-sniper.timer"
        systemctl daemon-reload >/dev/null 2>&1
        systemctl reset-failed  >/dev/null 2>&1
        rm -f "$BIN"
        rm -rf "$LIB_DIR"
        ok "systemd units and program removed"
    fi

    # docker side
    if [ -f "${DOCKER_DIR}/docker-compose.yml" ]; then
        (cd "$DOCKER_DIR" && docker compose down --remove-orphans >/dev/null 2>&1)
        ok "container stopped and removed"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx oracle-sniper; then
        docker rm -f oracle-sniper >/dev/null 2>&1
        ok "container removed"
    fi
    if have docker && docker image inspect "$IMAGE" >/dev/null 2>&1; then
        if ask_yn "Remove the container image as well?" y; then
            docker image rm "$IMAGE" >/dev/null 2>&1 && ok "image removed"
        fi
    fi
    rm -rf "$DOCKER_DIR"

    # the sensitive part
    say ""
    rule
    say "  ${B}Remove everything else too?${N}"
    say ""
    say "    ${CONFIG_FILE}"
    say "      your OCIDs, instance settings and notification tokens"
    say "    ${KEY_FILE}"
    say "      the private half of your Oracle API key"
    say "    ${STATE_DIR}"
    say "      run state, cached availability domains, logs of last errors"
    say ""
    say "  ${Y}This cannot be undone.${N} Keeping them lets you reinstall"
    say "  later without going through the setup again."
    rule
    if ask_yn "Delete config, credentials and state?" n; then
        rm -rf "$CONFIG_DIR" "$STATE_DIR"
        ok "Everything removed"
        say ""
        warn "Remember to revoke the API key in the OCI console:"
        info "Profile -> My profile -> API keys"
    else
        rm -rf "$STATE_DIR"
        ok "Config and key kept in ${CONFIG_DIR}"
        info "Run state removed"
    fi

    head1 "Done"
    say "  oracle-sniper has been uninstalled."
    say ""
    exit 0
}

# ------------------------------------------------------------ file fetch ---

fetch() {
    local src="$2"
    if [ -f "$(dirname "$0")/$1" ] && [ "${0##*/}" = "install.sh" ]; then
        install -m "$3" "$(dirname "$0")/$1" "$src"
    else
        curl -fsSL "${REPO_RAW}/$1" -o "$src" || fail "Download failed: $1"
        chmod "$3" "$src"
    fi
}

# ------------------------------------------------------------- configure ---

configure() {
    head1 "1. Oracle Cloud credentials"
    say "  ${D}OCI console: Profile -> My profile -> API keys. Adding a key there"
    say "  shows a snippet with exactly these three values.${N}"
    say ""
    ask_required "User OCID:"    "${OCI_USER:-}"    OCI_USER
    ask_required "Tenancy OCID:" "${OCI_TENANCY:-}" OCI_TENANCY
    ask_required "Region:"       "${OCI_REGION:-eu-frankfurt-1}" OCI_REGION
    ask          "Compartment OCID (blank = tenancy root):" "${OCI_COMPARTMENT:-}" OCI_COMPARTMENT
    [ -z "$OCI_COMPARTMENT" ] && OCI_COMPARTMENT="$OCI_TENANCY"

    head1 "2. API signing key"
    if [ -f "$KEY_FILE" ] && ask_yn "Reuse the existing key at ${KEY_FILE}?" y; then
        :
    else
        ask "Path to an existing private key (blank = generate one):" "" EXISTING_KEY
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
    say "  Fingerprint: ${B}${FINGERPRINT}${N}"
    say ""
    say "  ${D}If this key is not registered yet, paste the block below into"
    say "  Profile -> My profile -> API keys -> Add API key -> Paste a public key${N}"
    say ""
    openssl rsa -pubout -in "$KEY_FILE" 2>/dev/null | sed 's/^/    /'
    say ""
    ask "Press Enter once the key is registered." "" _

    head1 "3. Verifying API access"
    export OCI_USER OCI_TENANCY OCI_FINGERPRINT="$FINGERPRINT" OCI_REGION OCI_KEY_FILE="$KEY_FILE"
    # shellcheck source=/dev/null
    . "${LIB_DIR}/oci-api.sh"
    IAAS_HOST="$(oci_host iaas)"; IDENTITY_HOST="$(oci_host identity)"
    AD_LIST="$(oci_get "$IDENTITY_HOST" "/20160918/availabilityDomains?compartmentId=${OCI_COMPARTMENT}" \
                | tr ',' '\n' | grep -o '"name":"[^"]*"' | cut -d'"' -f4)"
    [ -n "$AD_LIST" ] || fail "API call failed. Check the OCIDs, the region, and that the key is registered.
   New keys sometimes need a minute before they authenticate."
    ok "API access works"
    printf '    %s\n' $AD_LIST

    head1 "4. Network"
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
    SUBNET_ID=""
    pick SUBNET_ID "subnet" < /tmp/.sniper-subnets || fail "No subnets found. Create a VCN first."
    rm -f /tmp/.sniper-subnets
    ASSIGN_PUBLIC_IP=true
    ask_yn "Assign a public IP?" y || ASSIGN_PUBLIC_IP=false

    head1 "5. Instance shape"
    say "  ${D}Always Free: VM.Standard.A1.Flex (Arm, 2 OCPU / 12 GB total)"
    say "               VM.Standard.E2.1.Micro (AMD, 1/8 OCPU / 1 GB)${N}"
    say ""
    ask "Shape:" "${SHAPE:-VM.Standard.A1.Flex}" SHAPE
    OCPUS=""; MEMORY_GB=""
    if printf '%s' "$SHAPE" | grep -qi 'flex'; then
        ask "OCPUs:" "${OCPUS:-2}" OCPUS
        ask "Memory in GB:" "${MEMORY_GB:-12}" MEMORY_GB
    fi
    ask "Boot volume size in GB:" "${BOOT_VOLUME_GB:-50}" BOOT_VOLUME_GB
    ask "Instance name:" "${INSTANCE_NAME:-free-instance}" INSTANCE_NAME

    head1 "6. Operating system image"
    ask "Operating system:" "Canonical Ubuntu" IMAGE_OS
    ask "Version:" "24.04" IMAGE_VER
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
        || fail "No image found for ${IMAGE_OS} ${IMAGE_VER} on ${SHAPE}."
    rm -f /tmp/.sniper-images

    head1 "7. SSH access"
    SSH_PUBLIC_KEY=""
    while [ -z "$SSH_PUBLIC_KEY" ]; do
        ask "Public key file, or paste the key:" "${HOME}/.ssh/id_ed25519.pub" SSH_IN
        if [ -r "$SSH_IN" ]; then
            SSH_PUBLIC_KEY="$(cat "$SSH_IN")"
        elif printf '%s' "$SSH_IN" | grep -qE '^(ssh-|ecdsa-)'; then
            SSH_PUBLIC_KEY="$SSH_IN"
        else
            warn "Not a readable file and not a public key."
        fi
    done
    ok "Key accepted ($(printf '%s' "$SSH_PUBLIC_KEY" | awk '{print $1}'))"
    warn "Make sure you hold the matching private key -- without it you cannot log in."
    ask "Default login user of that image:" "${SSH_USER:-ubuntu}" SSH_USER

    head1 "8. Notifications"
    say "  ${D}Optional. Without a channel, results only reach the log.${N}"
    say ""
    ask "Pushover application token:" "${NOTIFY_PUSHOVER_TOKEN:-}" NOTIFY_PUSHOVER_TOKEN
    [ -n "$NOTIFY_PUSHOVER_TOKEN" ] && ask "Pushover user key:" "${NOTIFY_PUSHOVER_USER:-}" NOTIFY_PUSHOVER_USER
    ask "ntfy topic URL:" "${NOTIFY_NTFY_URL:-}" NOTIFY_NTFY_URL
    ask "Webhook URL:" "${NOTIFY_WEBHOOK_URL:-}" NOTIFY_WEBHOOK_URL

    head1 "9. Schedule"
    say "  ${D}Oracle rate-limits aggressive polling. Ten minutes is a good default.${N}"
    say ""
    ask "Interval between attempts (systemd syntax, e.g. 10min):" "${CHECK_INTERVAL:-10min}" CHECK_INTERVAL

    umask 077
    cat > "$CONFIG_FILE" <<EOF
# oracle-sniper configuration
# Written by the installer on $(date -u +'%Y-%m-%d %H:%M:%S') UTC.

OCI_USER=${OCI_USER}
OCI_TENANCY=${OCI_TENANCY}
OCI_FINGERPRINT=${FINGERPRINT}
OCI_REGION=${OCI_REGION}
OCI_COMPARTMENT=${OCI_COMPARTMENT}
OCI_KEY_FILE=${KEY_FILE}

INSTANCE_NAME=${INSTANCE_NAME}
SHAPE=${SHAPE}
OCPUS=${OCPUS}
MEMORY_GB=${MEMORY_GB}
BOOT_VOLUME_GB=${BOOT_VOLUME_GB}
IMAGE_ID=${IMAGE_ID}
SUBNET_ID=${SUBNET_ID}
ASSIGN_PUBLIC_IP=${ASSIGN_PUBLIC_IP}

SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY}"
SSH_USER=${SSH_USER}

CLOUD_INIT_FILE=
AVAILABILITY_DOMAINS=

# Stop once the instance exists. Leave this on -- extra instances are billed.
STOP_WHEN_DONE=true

NOTIFY_PUSHOVER_TOKEN=${NOTIFY_PUSHOVER_TOKEN}
NOTIFY_PUSHOVER_USER=${NOTIFY_PUSHOVER_USER:-}
NOTIFY_NTFY_URL=${NOTIFY_NTFY_URL}
NOTIFY_WEBHOOK_URL=${NOTIFY_WEBHOOK_URL}
EOF
    chmod 600 "$CONFIG_FILE"
    ok "Configuration written to ${CONFIG_FILE}"
}

# --------------------------------------------------------------- install ---

install_systemd() {
    fetch bin/oracle-sniper "$BIN" 0755
    fetch bin/oci-api.sh "${LIB_DIR}/oci-api.sh" 0644
    fetch systemd/oracle-sniper.service "${UNIT_DIR}/oracle-sniper.service" 0644
    fetch systemd/oracle-sniper.timer "${UNIT_DIR}/oracle-sniper.timer" 0644
    ok "Files installed"

    [ -f "$CONFIG_FILE" ] || configure
    sed -i "s|^OnUnitActiveSec=.*|OnUnitActiveSec=${CHECK_INTERVAL:-10min}|" "${UNIT_DIR}/oracle-sniper.timer"
    systemctl daemon-reload
    ok "systemd units registered"

    head1 "Checking the setup"
    "$BIN" check || fail "Configuration check failed. Fix ${CONFIG_FILE}, then run: oracle-sniper check"

    if [ -n "${NOTIFY_PUSHOVER_TOKEN:-}${NOTIFY_NTFY_URL:-}${NOTIFY_WEBHOOK_URL:-}" ]; then
        ask_yn "Send a test notification?" y && "$BIN" test-notify
    fi

    head1 "Ready"
    if ask_yn "Start hunting now?" y; then
        systemctl enable --now oracle-sniper.timer
        ok "Timer active"
        systemctl list-timers oracle-sniper.timer --no-pager | head -3 | sed 's/^/  /'
    else
        info "Start later with: systemctl enable --now oracle-sniper.timer"
    fi

    cat <<EOF

  ${B}oracle-sniper status${N}   what is going on
  ${B}oracle-sniper run${N}      try once, right now
  ${B}journalctl -u oracle-sniper.service -f${N}

  Config: ${CONFIG_FILE}
  Re-run this installer to reconfigure or uninstall.

EOF
}

install_docker() {
    # The program is needed locally too, so `configure` can talk to the API.
    install -d -m 0755 "$LIB_DIR" "$STATE_DIR"
    fetch bin/oracle-sniper "$BIN" 0755
    fetch bin/oci-api.sh "${LIB_DIR}/oci-api.sh" 0644

    [ -f "$CONFIG_FILE" ] || configure

    local secs="600"
    case "${CHECK_INTERVAL:-10min}" in
        *min) secs=$(( ${CHECK_INTERVAL%min} * 60 )) ;;
        *h)   secs=$(( ${CHECK_INTERVAL%h} * 3600 )) ;;
        *s)   secs="${CHECK_INTERVAL%s}" ;;
    esac

    install -d -m 0755 "$DOCKER_DIR"
    cat > "${DOCKER_DIR}/docker-compose.yml" <<EOF
# Written by the oracle-sniper installer.
# On success the container exits 0 and must stay down -- hence on-failure.
services:
  oracle-sniper:
    image: ${IMAGE}
    container_name: oracle-sniper
    restart: on-failure
    environment:
      CHECK_INTERVAL_SECONDS: ${secs}
    volumes:
      - ${CONFIG_FILE}:/etc/oracle-sniper/config:ro
      - ${KEY_FILE}:/etc/oracle-sniper/api_key.pem:ro
      - sniper-state:/var/lib/oracle-sniper
    mem_limit: 64m
    cpus: 0.2

volumes:
  sniper-state:
EOF
    ok "Compose file written to ${DOCKER_DIR}/docker-compose.yml"

    head1 "Checking the setup"
    "$BIN" check || fail "Configuration check failed. Fix ${CONFIG_FILE}, then run: oracle-sniper check"

    if [ -n "${NOTIFY_PUSHOVER_TOKEN:-}${NOTIFY_NTFY_URL:-}${NOTIFY_WEBHOOK_URL:-}" ]; then
        ask_yn "Send a test notification?" y && "$BIN" test-notify
    fi

    head1 "Ready"
    if ask_yn "Pull the image and start hunting now?" y; then
        (cd "$DOCKER_DIR" && docker compose pull -q && docker compose up -d) \
            || fail "Could not start the container."
        ok "Container running"
        docker ps --filter name=oracle-sniper --format '  {{.Names}}  {{.Status}}'
    else
        info "Start later with: cd ${DOCKER_DIR} && docker compose up -d"
    fi

    cat <<EOF

  ${B}docker logs -f oracle-sniper${N}     follow the hunt
  ${B}oracle-sniper status${N}             what is going on
  ${B}docker compose -f ${DOCKER_DIR}/docker-compose.yml down${N}

  Config: ${CONFIG_FILE}
  Re-run this installer to reconfigure or uninstall.

EOF
}

# ------------------------------------------------------------------ main ---

[ "$(id -u)" = "0" ] || fail "Please run as root (sudo)."

banner
install -d -m 0755 "$LIB_DIR" "$STATE_DIR"
install -d -m 0700 "$CONFIG_DIR"

detect_install

if [ -n "$INSTALLED_MODE" ]; then
    head1 "Already installed"
    info "Mode: ${INSTALLED_MODE}"
    [ -f "$CONFIG_FILE" ] && info "Config: ${CONFIG_FILE}"
    CHOICE=""
    menu CHOICE "What would you like to do?" \
        "Reconfigure  ${D}(keep the installation, redo the setup)${N}" \
        "Uninstall    ${D}(remove it, optionally including credentials)${N}" \
        "Cancel"
    case "$CHOICE" in
        1) rm -f "$CONFIG_FILE"; info "Previous configuration removed; starting setup." ;;
        2) do_uninstall ;;
        3) say ""; info "Nothing changed."; exit 0 ;;
    esac
fi

MODE_CHOICE=""
head1 "How should it run?"
menu MODE_CHOICE "Choose:" \
    "systemd timer  ${D}(native, no Docker needed)${N}" \
    "Docker         ${D}(container, exits once the instance exists)${N}" \
    "Cancel"

case "$MODE_CHOICE" in
    1) check_requirements systemd; install_systemd ;;
    2) check_requirements docker;  install_docker ;;
    3) say ""; info "Nothing changed."; exit 0 ;;
esac
