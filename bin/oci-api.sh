#!/usr/bin/env bash
# Minimal Oracle Cloud Infrastructure REST client.
#
# Signs requests according to the HTTP Signature scheme OCI expects
# (draft-cavage-http-signatures). Needs nothing but curl and openssl --
# no Python, no SDK, no package installs.
#
# IMPORTANT: this file deliberately does NOT enable `set -e`.
# It gets sourced by the main script, and shell options leak into the
# caller. With `set -e` a single failing curl call would kill the caller
# silently, mid-run, without a log line. That exact bug once let an
# instance get created while the notification never went out.

OCI_API_LOADED=1

_oci_require_config() {
    local missing=()
    for v in OCI_USER OCI_TENANCY OCI_FINGERPRINT OCI_KEY_FILE; do
        [ -z "${!v:-}" ] && missing+=("$v")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing configuration values: ${missing[*]}" >&2
        return 1
    fi
    if [ ! -r "$OCI_KEY_FILE" ]; then
        echo "API key not readable: $OCI_KEY_FILE" >&2
        return 1
    fi
    return 0
}

_oci_key_id() { printf '%s/%s/%s' "$OCI_TENANCY" "$OCI_USER" "$OCI_FINGERPRINT"; }

_oci_sign() {
    printf '%s' "$1" | openssl dgst -sha256 -sign "$OCI_KEY_FILE" \
        | openssl enc -e -base64 | tr -d '\n'
}

_oci_date() { date -u +'%a, %d %b %Y %H:%M:%S GMT'; }

# oci_get <host> <path-with-query>
# Prints the response body. Returns curl's exit code.
oci_get() {
    local host="$1" target="$2" date_hdr sig
    date_hdr="$(_oci_date)"
    sig="$(_oci_sign "(request-target): get ${target}
host: ${host}
date: ${date_hdr}")"

    curl -sS --max-time "${OCI_HTTP_TIMEOUT:-30}" -X GET "https://${host}${target}" \
        -H "date: ${date_hdr}" \
        -H "host: ${host}" \
        -H "Authorization: Signature version=\"1\",keyId=\"$(_oci_key_id)\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date\",signature=\"${sig}\""
}

# _oci_body_request <method> <host> <path> <json>
# Prints the response body plus the HTTP status code on its own last line.
_oci_body_request() {
    local method="$1" host="$2" target="$3" body="$4"
    local date_hdr sha len sig lower
    lower="$(printf '%s' "$method" | tr 'A-Z' 'a-z')"
    date_hdr="$(_oci_date)"
    sha="$(printf '%s' "$body" | openssl dgst -sha256 -binary | openssl enc -e -base64 | tr -d '\n')"
    len="$(printf '%s' "$body" | wc -c)"

    sig="$(_oci_sign "(request-target): ${lower} ${target}
host: ${host}
date: ${date_hdr}
x-content-sha256: ${sha}
content-type: application/json
content-length: ${len}")"

    curl -sS --max-time "${OCI_HTTP_TIMEOUT_WRITE:-60}" -X "$method" "https://${host}${target}" \
        -H "date: ${date_hdr}" \
        -H "host: ${host}" \
        -H "x-content-sha256: ${sha}" \
        -H "content-type: application/json" \
        -H "content-length: ${len}" \
        -H "Authorization: Signature version=\"1\",keyId=\"$(_oci_key_id)\",algorithm=\"rsa-sha256\",headers=\"(request-target) host date x-content-sha256 content-type content-length\",signature=\"${sig}\"" \
        -w '\n%{http_code}' \
        --data-binary "$body"
}

# oci_post <host> <path> <json>   -> body + HTTP code on last line
oci_post() { _oci_body_request POST "$@"; }

# oci_put  <host> <path> <json>   -> body + HTTP code on last line
oci_put()  { _oci_body_request PUT  "$@"; }

# oci_host <service>  e.g. "iaas" / "identity" -> full API hostname
oci_host() { printf '%s.%s.oraclecloud.com' "$1" "$OCI_REGION"; }

# json_str <key>   reads the first "key":"value" pair from stdin.
# Good enough for OCIDs and states; not a general JSON parser.
json_str() {
    # Oracle answers compactly on some services and pretty-printed on others
    # ("key":"value" versus "key" : "value"). Matching only the compact form
    # returns nothing at all on the services that pad their colons -- with no
    # error, which makes it look like the field is simply absent.
    tr ',' '\n' \
        | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 \
        | sed -E 's/.*:[[:space:]]*"(.*)"$/\1/'
}
