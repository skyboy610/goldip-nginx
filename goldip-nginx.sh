#!/bin/bash
# ============================================================
#  GoldIP Nginx Camouflage Installer & Manager  v3.3.1
# ============================================================
# CHANGELOG (v3.3.1 - this revision):
#   5) Hardened response headers in the HTTPS server block:
#      - server_tokens off;  (hides the Nginx version string from
#        responses/error pages - removes an easy fingerprinting vector)
#      - Strict-Transport-Security (HSTS), since this config already
#        force-redirects HTTP -> HTTPS, so HSTS is always safe here
#      - X-XSS-Protection: 0  (the modern OWASP-recommended value;
#        the old "1; mode=block" is now considered a vulnerability
#        vector in some legacy browsers, so it is explicitly disabled
#        rather than enabled)
#      - All add_header directives now include "always" so they are
#        sent on error responses (4xx/5xx) too, not just 2xx/3xx
#      NOTE: Content-Security-Policy (CSP) was intentionally NOT added.
#      The camouflage feature can reverse-proxy to an arbitrary external
#      site chosen by the operator, and a CSP written for one site will
#      very likely break scripts/styles/fonts on a different site. A
#      site-specific CSP can be added by hand to the generated .conf
#      file if desired.
#
# CHANGELOG (v3.1 - this revision):
#   1) Color engine fixed: every prompt (ask/ask_optional/ask_number/
#      ask_port/ask_port_optional/ask_file/ask_choice) and every
#      ok/warn/err status line now cycles through a 12-color palette
#      instead of collapsing into a single washed-out white/cyan tone.
#   2) Install order changed: "Domain Panel" + "Panel Port" are now
#      asked FIRST, "CDN Domain" second (previously CDN domain was
#      asked before the panel domain).
#   3) CDN/reverse-proxy logic now applies ONLY to ws / httpupgrade /
#      xhttp (splithttp) inbounds. Every other protocol - Reality,
#      gRPC, TCP, KCP, QUIC, Hysteria/Hysteria2, TUIC, etc. - is left
#      100% untouched in the x-ui database (no listen/port/security/
#      externalProxy change of any kind), since those protocols
#      cannot be fronted by a CDN/reverse-proxy domain the way
#      ws/xhttp/httpupgrade can.
#   4) SSL certificate auto-discovery rewritten: now searches
#      certbot's live/ directory (exact match, numbered duplicate
#      folders, and a SAN/wildcard scan via openssl) plus acme.sh,
#      checking the CDN domain first and the Panel domain as
#      fallback. A certbot renewal deploy-hook is also installed so
#      Nginx auto-reloads after future certificate renewals.
# ============================================================
set -uo pipefail

RESET='\033[0m'
M1='\033[1;36m'; M2='\033[1;35m'; M3='\033[1;34m'; M4='\033[1;32m'
M5='\033[1;33m'; M6='\033[1;31m'; M7='\033[1;95m'; M8='\033[1;96m'
M9='\033[1;92m'; M10='\033[1;93m'; M11='\033[1;94m'; M12='\033[1;91m'
TITLE='\033[1;36m'; INFO='\033[1;34m'
OK_BG='\033[42m\033[97m'; WARN_BG='\033[43m\033[97m'; ERR_BG='\033[41m\033[97m'

# ---------------- Color engine ----------------
# Every ok/warn/err message body and every ask*/ask_choice prompt line
# pulls the next color out of this 12-color rotation, so two consecutive
# lines on screen are (almost) never the same color and nothing
# collapses to a single tone.
# NOTE: nextcolor() deliberately does NOT use "echo"/"printf" combined with
# command substitution (i.e. callers must NOT do c="$(nextcolor)"). Command
# substitution forks a subshell, so any mutation of __cidx inside it is lost
# the instant the subshell exits and every call would silently return the
# same color. Instead nextcolor() sets the global CURCOLOR variable directly;
# callers read $CURCOLOR right after calling it.
PALETTE=(M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11 M12)
__cidx=0
CURCOLOR=""
nextcolor() {
    local name="${PALETTE[$__cidx]}"
    __cidx=$(( (__cidx + 1) % ${#PALETTE[@]} ))
    CURCOLOR="${!name}"
}

ok()   { nextcolor; echo -e "${OK_BG} OK ${RESET}${CURCOLOR} $1${RESET}"; }
warn() { nextcolor; echo -e "${WARN_BG} WARN ${RESET}${CURCOLOR} $1${RESET}"; }
err()  { nextcolor; echo -e "${ERR_BG} ERROR ${RESET}${CURCOLOR} $1${RESET}"; }

NGINX_CONF_DIR="/etc/nginx/conf.d"
CAMO_ROOT="/var/www/goldip"

# GoldIP trusted domain - always whitelisted in firewall
GOLDIP_TRUSTED="goldip.net"

CF_V4_DEFAULT="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF_V6_DEFAULT="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
ARVAN_V4_DEFAULT="178.131.120.48/28 185.143.232.0/22 185.215.232.0/22 188.229.116.16/30 2.144.3.128/28 37.32.16.0/27 37.32.17.0/27 37.32.18.0/27 37.32.19.0/27 78.157.36.112/28 94.101.182.0/27 94.101.183.0/28"
ARVAN_V6_DEFAULT=""
CF_V4=""; CF_V6=""; ARVAN_V4=""; ARVAN_V6=""

# ---------------- Input helpers ----------------
ask() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans __c
    while true; do
        nextcolor; __c="$CURCOLOR"
        if [ -n "$__hint" ]; then
            echo -e "${__c}${__q} ${__hint}:${RESET}"
        else
            echo -e "${__c}${__q}:${RESET}"
        fi
        read -r __ans
        [ -n "$__ans" ] && { printf -v "$__var" '%s' "$__ans"; return 0; }
        warn "This field can't be empty. Please try again."
    done
}
ask_optional() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans __c
    nextcolor; __c="$CURCOLOR"
    if [ -n "$__hint" ]; then
        echo -e "${__c}${__q} ${__hint}:${RESET}"
    else
        echo -e "${__c}${__q}:${RESET}"
    fi
    read -r __ans; printf -v "$__var" '%s' "$__ans"
}
ask_number() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans __c
    while true; do
        nextcolor; __c="$CURCOLOR"
        if [ -n "$__hint" ]; then
            echo -e "${__c}${__q} ${__hint}:${RESET}"
        else
            echo -e "${__c}${__q}:${RESET}"
        fi
        read -r __ans
        case "$__ans" in ''|*[!0-9]*) warn "Must be a number."; continue ;; esac
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}
ask_port() {
    local __var="$1" __q="$2" __def="$3" __ans __c
    while true; do
        nextcolor; __c="$CURCOLOR"
        echo -e "${__c}${__q} [${__def}]:${RESET}"
        read -r __ans
        [ -n "$__ans" ] || __ans="$__def"
        case "$__ans" in ''|*[!0-9]*) warn "Port must be a number."; continue ;; esac
        { [ "$__ans" -ge 1 ] && [ "$__ans" -le 65535 ]; } || { warn "Port out of range."; continue; }
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}
ask_port_optional() {
    local __var="$1" __q="$2" __ans __c
    while true; do
        nextcolor; __c="$CURCOLOR"
        echo -e "${__c}${__q} (blank to skip):${RESET}"
        read -r __ans
        [ -z "$__ans" ] && { printf -v "$__var" '%s' ""; return 0; }
        case "$__ans" in *[!0-9]*) warn "Port must be a number."; continue ;; esac
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}
ask_file() {
    local __var="$1" __q="$2" __ans __c
    while true; do
        nextcolor; __c="$CURCOLOR"
        echo -e "${__c}${__q}:${RESET}"
        read -r __ans
        [ -z "$__ans" ] && { warn "Path can't be empty."; continue; }
        [ -f "$__ans" ] || { err "File not found: $__ans"; continue; }
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}
ask_choice() {
    local __var="$1" __q="$2" __valid="$3" __ans __c
    while true; do
        nextcolor; __c="$CURCOLOR"
        echo -e "${__c}${__q} [${__valid//|//}]:${RESET}"
        read -r __ans
        printf '%s' "$__ans" | grep -qiE "^(${__valid})$" && { printf -v "$__var" '%s' "$__ans"; return 0; }
        warn "Invalid choice. Allowed: ${__valid//|/, }"
    done
}
is_yes() { case "$1" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac; }

# Strip scheme from domain input (user may type https://example.com or example.com)
strip_scheme() {
    printf '%s' "$1" | sed -E 's#^https?://##; s#/.*##; s/^[[:space:]]+//; s/[[:space:]]+$//'
}
# Strip a trailing :port from a host string (e.g. when a user types IP:port
# into a field that should hold the host only - the port is asked separately).
strip_port() {
    printf '%s' "$1" | sed -E 's/:[0-9]+$//'
}

# ---------------- Header ----------------
header() {
cat <<'EOF'
==========================================================
   ____       _     _ ___ ____
  / ___| ___ | | __| |_ _|  _ \
 | |  _ / _ \| |/ _` || || |_) |
 | |_| | (_) | | (_| || ||  __/
  \____|\___/|_|\__,_|___|_|
    N G I N X   C A M O U F L A G E   v3.3.1
==========================================================
EOF
}

require_root() {
    [ "$(id -u)" -eq 0 ] || { err "Run this script as root."; exit 1; }
}

# ---------------- Ensure sqlite3 ----------------
ensure_sqlite3() {
    command -v sqlite3 >/dev/null 2>&1 && return 0
    warn "sqlite3 not found. Installing..."
    if ls ./sqlite-offline/*.deb >/dev/null 2>&1; then
        dpkg -i ./sqlite-offline/*.deb >/dev/null 2>&1
        apt-get install -f -y >/dev/null 2>&1
    else
        apt-get update -y >/dev/null 2>&1
        apt-get install -y sqlite3 >/dev/null 2>&1
    fi
    command -v sqlite3 >/dev/null 2>&1 && { ok "sqlite3 installed."; return 0; }
    warn "Could not install sqlite3."; return 1
}

# ---------------- Install Nginx ----------------
install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        ok "Nginx already installed ($(nginx -v 2>&1 | sed 's#.*/##'))."; return 0
    fi
    warn "Nginx not found. Installing..."
    if ls ./nginx-offline/*.deb >/dev/null 2>&1; then
        dpkg -i ./nginx-offline/*.deb >/dev/null 2>&1
        apt-get install -f -y >/dev/null 2>&1
        command -v nginx >/dev/null 2>&1 || { err "Offline install failed."; exit 1; }
        ok "Nginx installed from local packages."
    else
        apt-get update -y >/dev/null 2>&1 && apt-get install -y nginx >/dev/null 2>&1 \
            && ok "Nginx installed from repository." \
            || { err "Repository install failed."; exit 1; }
    fi
}

# ---------------- Browser-realistic location blocks ----------------
make_location() {
    local t="$1" p="$2" port="$3"
    if [ "$t" = "xhttp" ]; then
        printf '    location %s {\n' "$p"
        printf '        proxy_pass http://127.0.0.1:%s;\n' "$port"
        printf '        proxy_http_version 1.1;\n'
        printf '        proxy_set_header Host $host;\n'
        printf '        proxy_set_header X-Real-IP $remote_addr;\n'
        printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
        printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
        printf '        proxy_set_header Origin $scheme://$host;\n'
        printf '        proxy_set_header Sec-Fetch-Site same-origin;\n'
        printf '        proxy_set_header Sec-Fetch-Mode cors;\n'
        printf '        proxy_set_header Sec-Fetch-Dest empty;\n'
        printf '        proxy_set_header Accept */*;\n'
        printf '        proxy_set_header Accept-Language "en-US,en;q=0.9";\n'
        printf '        proxy_set_header Cache-Control no-cache;\n'
        printf '        proxy_set_header Pragma no-cache;\n'
        printf '        proxy_pass_request_headers on;\n'
        printf '        proxy_buffering off;\n'
        printf '        proxy_request_buffering off;\n'
        printf '        proxy_read_timeout 300s;\n'
        printf '        proxy_send_timeout 300s;\n'
        printf '    }\n'
    else
        # ws / httpupgrade
        printf '    location %s {\n' "$p"
        printf '        proxy_pass http://127.0.0.1:%s;\n' "$port"
        printf '        proxy_http_version 1.1;\n'
        printf '        proxy_set_header Upgrade $http_upgrade;\n'
        printf '        proxy_set_header Connection "upgrade";\n'
        printf '        proxy_set_header Host $host;\n'
        printf '        proxy_set_header X-Real-IP $remote_addr;\n'
        printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
        printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
        printf '        proxy_set_header Origin $scheme://$host;\n'
        printf '        proxy_set_header Sec-WebSocket-Version 13;\n'
        printf '        proxy_set_header Sec-Fetch-Site same-origin;\n'
        printf '        proxy_set_header Sec-Fetch-Mode websocket;\n'
        printf '        proxy_set_header Sec-Fetch-Dest websocket;\n'
        printf '        proxy_set_header Accept-Language "en-US,en;q=0.9";\n'
        printf '        proxy_set_header Cache-Control no-cache;\n'
        printf '        proxy_set_header Pragma no-cache;\n'
        printf '        proxy_pass_request_headers on;\n'
        printf '        proxy_read_timeout 300s;\n'
        printf '        proxy_send_timeout 300s;\n'
        printf '    }\n'
    fi
}

# ---------------- Find a free local port ----------------
free_port() {
    local p
    for p in $(seq 20000 29999); do
        case " $USED_PORTS " in *" $p "*) continue ;; esac
        case " $TAKEN_PORTS " in *" $p "*) continue ;; esac
        echo "$p"; return 0
    done; return 1
}

# ---------------- Resolve IPs for a domain ----------------
resolve_domain_ips() {
    local domain="$1" ips=""
    # Try dig, then host, then getent
    if command -v dig >/dev/null 2>&1; then
        ips=$(dig +short A "$domain" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' ')
    fi
    if [ -z "$ips" ] && command -v host >/dev/null 2>&1; then
        ips=$(host -t A "$domain" 2>/dev/null | awk '/has address/{print $4}' | tr '\n' ' ')
    fi
    if [ -z "$ips" ] && command -v getent >/dev/null 2>&1; then
        ips=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    fi
    printf '%s' "$ips"
}

# ---------------- Transform inbound JSON ----------------
# Only ever called for CDN-compatible inbounds (ws / httpupgrade / xhttp).
# Nginx terminates TLS in front of these, so the inbound itself goes
# plaintext (security=none) and externalProxy is set so 3x-ui generates
# correct client / subscription links pointing at the CDN domain.
#
# IMPORTANT: this function is NEVER called for any other protocol
# (Reality, gRPC, TCP, KCP, QUIC, Hysteria/Hysteria2, TUIC, etc.) - those
# are left completely untouched by the caller, see auto_build_locations().
transform_inbound_json() {
    python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys

raw, domain, hport = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    ss = json.loads(raw)
except Exception:
    sys.exit(2)
if not isinstance(ss, dict):
    sys.exit(2)

ss["security"] = "none"
for k in ("tlsSettings", "realitySettings", "externalProxySettings", "externalProxy"):
    ss.pop(k, None)
try:
    port = int(hport)
except ValueError:
    port = 443
ss["externalProxy"] = [{
    "forceTls":    "tls",
    "dest":        domain,
    "port":        port,
    "remark":      "",
    "sni":         domain,
    "fingerprint": "chrome",
    "alpn":        "h2,http/1.1"
}]

json.dump(ss, sys.stdout, separators=(",", ":"), ensure_ascii=False)
PYEOF
}

# ---------------- Detect x-ui database & panel/sub ports ----------------
detect_xui_ports() {
    XUI_DB=""
    local c
    for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do
        [ -f "$c" ] && XUI_DB="$c" && break
    done
    XUI_PANEL_PORT_DETECTED=""
    XUI_SUB_PORT_DETECTED=""
    [ -n "$XUI_DB" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    XUI_PANEL_PORT_DETECTED=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" 2>/dev/null)
    [ -z "$XUI_PANEL_PORT_DETECTED" ] && \
        XUI_PANEL_PORT_DETECTED=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='port' LIMIT 1;" 2>/dev/null)
    XUI_SUB_PORT_DETECTED=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPort' LIMIT 1;" 2>/dev/null)
    return 0
}

# ---------------- Automatic SSL certificate discovery ----------------
# Searches, in order:
#   1) exact certbot path:           /etc/letsencrypt/live/<domain>/
#   2) certbot numbered duplicates:  /etc/letsencrypt/live/<domain>-0001/
#   3) every certbot cert, matching the domain against the cert's SAN
#      list (handles wildcard certs and certs filed under an unrelated
#      folder name)
#   4) acme.sh:                      ~/.acme.sh/<domain>*/
# Prints "certpath|keypath" and returns 0 on success, returns 1 if
# nothing was found.
find_certificate_for_domain() {
    local domain d key sans wildcard_base
    domain=$(strip_port "${1:-}")
    [ -n "$domain" ] || return 1

    # 1) exact match
    if [ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ] && \
       [ -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]; then
        printf '%s|%s' "/etc/letsencrypt/live/${domain}/fullchain.pem" \
                        "/etc/letsencrypt/live/${domain}/privkey.pem"
        return 0
    fi

    # 2) certbot numbered duplicates (domain-0001, domain-0002, ...)
    for d in /etc/letsencrypt/live/"${domain}"-[0-9]*/; do
        [ -f "${d}fullchain.pem" ] && [ -f "${d}privkey.pem" ] || continue
        printf '%s|%s' "${d}fullchain.pem" "${d}privkey.pem"
        return 0
    done

    # 3) scan every certbot cert for a SAN / wildcard match
    if command -v openssl >/dev/null 2>&1 && [ -d /etc/letsencrypt/live ]; then
        wildcard_base="${domain#*.}"
        for d in /etc/letsencrypt/live/*/; do
            [ -f "${d}fullchain.pem" ] && [ -f "${d}privkey.pem" ] || continue
            sans=$(openssl x509 -noout -text -in "${d}fullchain.pem" 2>/dev/null \
                     | grep -A1 'Subject Alternative Name' | tail -n1)
            if printf '%s' "$sans" | grep -qiE "DNS:${domain//./\\.}(,|\$)"; then
                printf '%s|%s' "${d}fullchain.pem" "${d}privkey.pem"
                return 0
            fi
            if [ -n "$wildcard_base" ] && printf '%s' "$sans" | grep -qiE "DNS:\*\.${wildcard_base//./\\.}(,|\$)"; then
                printf '%s|%s' "${d}fullchain.pem" "${d}privkey.pem"
                return 0
            fi
        done
    fi

    # 4) acme.sh (covers both standard and _ecc cert directories)
    for d in "${HOME}/.acme.sh/${domain}"*/; do
        [ -f "${d}fullchain.cer" ] || continue
        key=""
        for kf in "${d}"*.key; do
            [ -f "$kf" ] || continue
            case "$kf" in */ca.key) continue ;; esac
            key="$kf"; break
        done
        [ -n "$key" ] || continue
        printf '%s|%s' "${d}fullchain.cer" "$key"
        return 0
    done

    return 1
}

# Installs a certbot deploy-hook so Nginx auto-reloads whenever this
# certificate gets renewed in the future (only applies to certbot-managed
# certs - a no-op for manually supplied / acme.sh certs).
ensure_cert_renew_hook() {
    local cert_path="${1:-}"
    case "$cert_path" in
        /etc/letsencrypt/live/*) : ;;
        *) return 0 ;;
    esac
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    mkdir -p "$hook_dir" 2>/dev/null || return 0
    cat > "${hook_dir}/goldip-nginx-reload.sh" <<'CERTHOOK_EOF'
#!/bin/bash
nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
CERTHOOK_EOF
    chmod +x "${hook_dir}/goldip-nginx-reload.sh" 2>/dev/null
    ok "Certbot renewal hook installed (Nginx auto-reloads after future renewals)."
}

# ---------------- Auto build locations from x-ui DB ----------------
# CDN-compatible (ws/httpupgrade/xhttp only):
#   - move to 127.0.0.1, security=none, externalProxy=CDN_DOMAIN:HTTPS_PORT
# Every other protocol (Reality, gRPC, TCP, KCP, QUIC, Hysteria/Hysteria2,
# TUIC, etc.):
#   - left 100% UNTOUCHED. No listen change, no port change, no security
#     change, no externalProxy. These protocols are not HTTP/WS-based and
#     cannot be fronted by a CDN/reverse-proxy domain - forcing them
#     through one breaks the protocol entirely.
auto_build_locations() {
    local db=""
    for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do
        [ -f "$c" ] && db="$c" && break
    done
    if [ -z "$db" ]; then
        ask_optional db "x-ui.db not found. Enter full path" "(blank to cancel)"
        { [ -n "$db" ] && [ -f "$db" ]; } || { warn "No database found."; return 1; }
    fi
    ensure_sqlite3 || return 1
    ok "Reading inbounds from: $db"

    local -a IN_ID IN_PORT IN_NET IN_PATH IN_SS IN_PROTO
    local idx=0 id port ss net rawpath path proto
    while IFS='|' read -r id port ss proto; do
        [ -n "$port" ] || continue
        case "$id"   in ''|*[!0-9]*) continue ;; esac
        case "$port" in    *[!0-9]*) continue ;; esac
        net=$(printf '%s' "$ss" | grep -oE '"network"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        rawpath=$(printf '%s' "$ss" | grep -oE '"path"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        path="${rawpath%%\?*}"
        idx=$((idx+1))
        IN_ID[$idx]="$id";    IN_PORT[$idx]="$port"
        IN_NET[$idx]="${net:-unknown}"; IN_PATH[$idx]="$path"
        IN_SS[$idx]="$ss";    IN_PROTO[$idx]="${proto:-}"
    done < <(sqlite3 -separator '|' "$db" \
        "SELECT id, port, replace(replace(stream_settings, char(10), ' '), char(13), ' '), protocol FROM inbounds;" 2>/dev/null)

    [ "$idx" -ge 1 ] || { warn "No inbounds found in database."; return 1; }

    echo -e "${INFO}Inbounds found:${RESET}"
    local n
    for n in $(seq 1 "$idx"); do
        printf "  ${M8}*${RESET} ${M4}port %-6s${RESET} | ${M5}%-12s${RESET} | ${M1}%s${RESET} | proto: %s\n" \
            "${IN_PORT[$n]}" "${IN_NET[$n]}" "${IN_PATH[$n]:-(no path)}" "${IN_PROTO[$n]:-?}"
    done

    LOCATIONS=""
    local cdn_added=0 skipped_other=0 skipped_path=0 skipped_dup=0
    local SQL_CDN=""
    USED_PORTS=$(ss -ltn 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': ' | tr '\n' ' ')
    TAKEN_PORTS=""; SEEN_PATHS=""

    local HAVE_PY=0
    command -v python3 >/dev/null 2>&1 && HAVE_PY=1
    [ "$HAVE_PY" = "1" ] || warn "python3 not found: CDN inbounds will move ports but keep their existing security/TLS settings untouched."

    local ltype fport inb_id newjson is_cdn
    for n in $(seq 1 "$idx"); do
        port="${IN_PORT[$n]}"; net="${IN_NET[$n]}"
        path="${IN_PATH[$n]}"; inb_id="${IN_ID[$n]}"

        is_cdn=0
        case "$net" in
            ws|httpupgrade)  is_cdn=1; ltype="upgrade" ;;
            xhttp|splithttp) is_cdn=1; ltype="xhttp"   ;;
        esac

        if [ "$is_cdn" != "1" ]; then
            # Anything that is not ws / httpupgrade / xhttp is left 100%
            # untouched: gRPC, Reality, TCP, KCP, QUIC, Hysteria/Hysteria2,
            # TUIC, etc. cannot be fronted by a CDN/reverse-proxy domain.
            ok "Untouched (not CDN-compatible): ${net} port ${port}"
            skipped_other=$((skipped_other+1))
            continue
        fi

        # CDN-compatible: must have a unique, non-root path
        if [ -z "$path" ] || [ "$path" = "/" ]; then
            warn "Skip CDN inbound port ${port}: no valid path (${path:-empty})"
            skipped_path=$((skipped_path+1)); continue
        fi
        case " $SEEN_PATHS " in
            *" $path "*) warn "Skip CDN inbound port ${port}: duplicate path ${path}"
                         skipped_dup=$((skipped_dup+1)); continue ;;
        esac
        SEEN_PATHS="${SEEN_PATHS} ${path}"

        # Move off nginx ports if needed (only renumber, never force a
        # fixed port like 443 onto the inbound - it keeps its own port
        # unless it collides with the Nginx HTTPS/HTTP listener)
        fport="$port"
        if [ "$port" = "$HTTPS_PORT" ] || [ "$port" = "$HTTP_PORT" ]; then
            fport=$(free_port) || { err "No free local port available."; return 1; }
            warn "Port ${port} conflicts with Nginx -> moving to 127.0.0.1:${fport}"
        fi
        TAKEN_PORTS="${TAKEN_PORTS} ${fport}"

        if [ "$HAVE_PY" = "1" ]; then
            if newjson=$(transform_inbound_json "${IN_SS[$n]}" "$CDN_DOMAIN" "$HTTPS_PORT" 2>/dev/null); then
                newjson="${newjson//\'/\'\'}"
                SQL_CDN="${SQL_CDN}UPDATE inbounds SET listen='127.0.0.1', port=${fport}, stream_settings='${newjson}' WHERE id=${inb_id};"$'\n'
                ok "CDN: ${net} ${path} -> 127.0.0.1:${fport} | extProxy: ${CDN_DOMAIN}:${HTTPS_PORT}"
            else
                warn "JSON parse failed for port ${port}, simple TLS-off only."
                SQL_CDN="${SQL_CDN}UPDATE inbounds SET listen='127.0.0.1', port=${fport} WHERE id=${inb_id};"$'\n'
                ok "CDN: ${net} ${path} -> 127.0.0.1:${fport} (no extProxy)"
            fi
        else
            SQL_CDN="${SQL_CDN}UPDATE inbounds SET listen='127.0.0.1', port=${fport} WHERE id=${inb_id};"$'\n'
            ok "CDN: ${net} ${path} -> 127.0.0.1:${fport}"
        fi

        LOCATIONS="${LOCATIONS}"$'\n'"$(make_location "$ltype" "$path" "$fport")"
        cdn_added=$((cdn_added+1))
    done

    echo ""
    echo -e "${INFO}Summary:${RESET}"
    echo -e "  ${M4}CDN inbounds behind Nginx: ${cdn_added}${RESET}"
    echo -e "  ${M5}Left untouched (non-CDN protocols): ${skipped_other}${RESET}"
    echo -e "  ${M8}Skipped (no path): ${skipped_path} | Skipped (dup path): ${skipped_dup}${RESET}"

    [ "$cdn_added" -ge 1 ] || { warn "No CDN-compatible inbounds found (need ws/httpupgrade/xhttp with a path)."; return 1; }

    if [ -n "$SQL_CDN" ]; then
        echo ""
        echo -e "${WARN_BG} ACTION ${RESET} Apply DB changes?"
        echo -e "  ${M4}CDN inbounds (ws/httpupgrade/xhttp)${RESET}: move to 127.0.0.1 + set extProxy to ${CDN_DOMAIN}:${HTTPS_PORT}"
        echo -e "  ${M5}Every other protocol${RESET}: left completely unmodified (no DB change at all)"
        local AP; ask_optional AP "Apply now?" "[y/N]"
        if is_yes "$AP"; then
            local bak="${db}.bak.$(date +%s)"
            cp "$db" "$bak" && ok "DB backed up: $bak" || { err "Backup failed."; return 0; }
            if printf '%s\n' "$SQL_CDN" | sqlite3 "$db" 2>/tmp/sql_err.log; then
                ok "Database updated."
                systemctl restart x-ui 2>/dev/null && ok "x-ui restarted." \
                    || warn "Could not restart x-ui. Run: x-ui restart"
            else
                err "DB update failed; restoring backup."; cp "$bak" "$db"; cat /tmp/sql_err.log
            fi
        else
            warn "Skipped DB change."
        fi
    fi
    return 0
}

# ---------------- Gather inputs ----------------
gather_inputs() {
    detect_xui_ports

    echo -e "${INFO}=== Panel Configuration ===${RESET}"
    ask RAW_PANEL_DOMAIN "Domain Panel" "(e.g. panel.goldip.me or server IP)"
    PANEL_DOMAIN=$(strip_scheme "$RAW_PANEL_DOMAIN")
    PANEL_DOMAIN=$(strip_port "$PANEL_DOMAIN")
    ask_port PANEL_PORT "Panel Port" "${XUI_PANEL_PORT_DETECTED:-2053}"
    XUI_PANEL_PORT="$PANEL_PORT"
    ok "Panel: ${PANEL_DOMAIN}:${PANEL_PORT}"

    echo -e "${INFO}=== CDN Configuration ===${RESET}"
    ask RAW_CDN_DOMAIN "CDN Domain" "(e.g. tu.goldip.me)"
    CDN_DOMAIN=$(strip_scheme "$RAW_CDN_DOMAIN")
    PRIMARY="$CDN_DOMAIN"
    ok "CDN domain: ${CDN_DOMAIN}"

    ask_port HTTPS_PORT "HTTPS listen port (CDN)" 443
    ask_port HTTP_PORT  "HTTP  listen port"       80

    echo -e "${INFO}=== TLS Certificate ===${RESET}"
    AUTO_CERT=""; AUTO_KEY=""
    local FOUND
    FOUND="$(find_certificate_for_domain "$CDN_DOMAIN")" && IFS='|' read -r AUTO_CERT AUTO_KEY <<<"$FOUND"
    if [ -z "$AUTO_CERT" ]; then
        FOUND="$(find_certificate_for_domain "$PANEL_DOMAIN")" && IFS='|' read -r AUTO_CERT AUTO_KEY <<<"$FOUND"
    fi

    if [ -n "$AUTO_CERT" ] && [ -f "$AUTO_CERT" ] && [ -f "$AUTO_KEY" ]; then
        ok "Certificate found automatically:"
        ok "cert : ${AUTO_CERT}"
        ok "key  : ${AUTO_KEY}"
        local USE_AUTO
        ask_optional USE_AUTO "Use these certificates?" "[Y/n]"
        case "$USE_AUTO" in
            n|N|no|NO)
                ask_file SSL_CERT "Full path to SSL certificate (fullchain.pem)"
                ask_file SSL_KEY  "Full path to SSL private key (privkey.pem)"
                ;;
            *)
                SSL_CERT="$AUTO_CERT"
                SSL_KEY="$AUTO_KEY"
                ;;
        esac
    else
        warn "No certificate found automatically for ${CDN_DOMAIN} or ${PANEL_DOMAIN}."
        warn "Searched: /etc/letsencrypt/live/* (incl. numbered dirs + wildcard/SAN match), ~/.acme.sh/*"
        ask_file SSL_CERT "Full path to SSL certificate (fullchain.pem)"
        ask_file SSL_KEY  "Full path to SSL private key (privkey.pem)"
    fi
    ensure_cert_renew_hook "$SSL_CERT"

    ask_optional BEHIND_CF "Behind Cloudflare CDN? (restore real visitor IP)" "[y/N]"

    LOCATIONS=""
    echo -e "${INFO}=== Inbound Configuration ===${RESET}"
    ok "Only ws / httpupgrade / xhttp inbounds can be fronted by ${CDN_DOMAIN}."
    ok "Every other protocol (Reality, gRPC, TCP, KCP, QUIC, Hysteria/Hysteria2, TUIC, ...) stays untouched."
    echo -e "  ${M1}1)${RESET} ${M4}Auto (read from x-ui database)${RESET}"
    echo -e "  ${M2}2)${RESET} ${M5}Manual entry${RESET}"
    ask_choice DISC "Selection" "1|2"

    if [ "$DISC" = "1" ] && auto_build_locations; then
        ok "Locations built automatically."
    else
        [ "$DISC" = "1" ] && warn "Auto-build failed, switching to manual."
        ask_number NIN "How many CDN inbounds to add to Nginx?"
        local i=1
        while [ "$i" -le "$NIN" ]; do
            echo -e "${INFO}--- Inbound #${i} ---${RESET}"
            ask P_PATH "Path" "(e.g. /ws${i})"
            [ "${P_PATH:0:1}" = "/" ] || P_PATH="/$P_PATH"
            ask_number P_PORT "Local Xray port"
            echo -e "${INFO}Transport:${RESET}"
            echo -e "  ${M1}1)${RESET} WebSocket  ${M2}2)${RESET} HTTPUpgrade  ${M3}3)${RESET} XHTTP"
            ask_choice P_TYPE "Selection" "1|2|3"
            case "$P_TYPE" in
                1|2) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location upgrade "$P_PATH" "$P_PORT")" ;;
                3)   LOCATIONS="${LOCATIONS}"$'\n'"$(make_location xhttp   "$P_PATH" "$P_PORT")" ;;
            esac
            i=$((i+1))
        done
    fi

    echo -e "${INFO}=== Camouflage Site ===${RESET}"
    echo -e "  ${M1}1)${RESET} ${M4}Reverse-proxy to existing website${RESET}"
    echo -e "  ${M2}2)${RESET} ${M5}Serve local HTML file${RESET}"
    ask_choice CAMO "Selection" "1|2"

    if [ "$CAMO" = "1" ]; then
        ask RAW_PROXY "Website to proxy" "(e.g. example.com  or  https://example.com)"
        RAW_PROXY=$(printf '%s' "$RAW_PROXY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$RAW_PROXY" in http://*|https://*) PROXY_URL="$RAW_PROXY" ;; *) PROXY_URL="https://${RAW_PROXY}" ;; esac
        PROXY_SCHEME=$(printf '%s' "$PROXY_URL" | grep -oE '^https?')
        PROXY_HOST=$(printf '%s' "$PROXY_URL" | sed -E 's#^https?://##; s#/.*##')
        PROXY_BASEPATH=$(printf '%s' "$PROXY_URL" | sed -E 's#^https?://[^/]*##')
        [ -z "$PROXY_BASEPATH" ] && PROXY_BASEPATH="/"
        [ "$PROXY_SCHEME" = "http" ] && warn "HTTP origin over HTTPS may cause mixed content issues."
        ok "Proxying: ${PROXY_SCHEME}://${PROXY_HOST}${PROXY_BASEPATH}"
        _build_camo_block
    else
        ask_file HTML_FILE "Full path to your index.html"
        mkdir -p "$CAMO_ROOT"
        cp "$HTML_FILE" "$CAMO_ROOT/index.html"
        CAMO_BLOCK="location / {
        root ${CAMO_ROOT};
        index index.html;
    }"
    fi
}

# ---------------- Build camouflage reverse-proxy block ----------------
_build_camo_block() {
    local js_file="/tmp/goldip_js_$$.js"
    cat > "$js_file" <<JSEOF
<script>(function(){var H="PROXY_HOST_PH",S="PROXY_SCHEME_PH";var r1=new RegExp(S+"://"+H.replace(/\./g,"\\."),\"g\");var r2=new RegExp("//"+H.replace(/\./g,"\\."),\"g\");function c(u){return typeof u==="string"?u.replace(r1,"").replace(r2,""):u;}var oF=window.fetch;window.fetch=function(u,o){return oF.call(this,c(u),o);};var oX=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){return oX.apply(this,[m,c(u)].concat(Array.prototype.slice.call(arguments,2)));};var oP=history.pushState,oR=history.replaceState;history.pushState=function(s,t,u){return oP.call(this,s,t,c(u));};history.replaceState=function(s,t,u){return oR.call(this,s,t,c(u));};try{var dl=Object.getOwnPropertyDescriptor(window.location,"href");if(dl&&dl.set){Object.defineProperty(window.location,"href",{set:function(v){window.history.replaceState(null,"",c(v));},get:dl.get,configurable:true});}}catch(e){}document.addEventListener("click",function(e){var a=e.target.closest("a");if(!a)return;var h=a.getAttribute("href")||\"\";if(r1.test(h)||r2.test(h)){e.preventDefault();window.history.pushState(null,"",c(h));}},true);})();</script>
JSEOF
    local js_inline
    js_inline=$(sed "s|PROXY_HOST_PH|${PROXY_HOST}|g; s|PROXY_SCHEME_PH|${PROXY_SCHEME}|g" "$js_file" | tr -d '\n')
    rm -f "$js_file"

    CAMO_BLOCK="# Camouflage reverse-proxy
    gzip off;
    sub_filter_once off;
    sub_filter_types text/html text/css text/xml text/plain text/javascript application/javascript application/json;
    sub_filter '${PROXY_SCHEME}://${PROXY_HOST}' '';
    sub_filter 'https://${PROXY_HOST}' '';
    sub_filter 'http://${PROXY_HOST}' '';
    sub_filter '//${PROXY_HOST}' '';

    location / {
        proxy_pass ${PROXY_SCHEME}://${PROXY_HOST}${PROXY_BASEPATH};
        proxy_ssl_server_name on;
        proxy_set_header Host ${PROXY_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Referer '${PROXY_SCHEME}://${PROXY_HOST}/';
        proxy_set_header Accept 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7';
        proxy_set_header Accept-Language 'en-US,en;q=0.9';
        proxy_set_header Accept-Encoding 'identity';
        proxy_set_header Cache-Control 'max-age=0';
        proxy_set_header Sec-Fetch-Dest 'document';
        proxy_set_header Sec-Fetch-Mode 'navigate';
        proxy_set_header Sec-Fetch-Site 'same-origin';
        proxy_set_header Sec-Fetch-User '?1';
        proxy_set_header Upgrade-Insecure-Requests '1';
        proxy_set_header DNT '1';
        proxy_redirect ${PROXY_SCHEME}://${PROXY_HOST}/ /;
        proxy_redirect //${PROXY_HOST}/ /;
        proxy_cookie_domain ${PROXY_HOST} \$host;
        proxy_cookie_path / /;
        sub_filter '</head>' '${js_inline}</head>';
        proxy_http_version 1.1;
        proxy_set_header Connection '';
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        proxy_buffers 32 16k;
        proxy_buffer_size 32k;
    }"
}

# ---------------- Write nginx config ----------------
write_config() {
    mkdir -p "$NGINX_CONF_DIR"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null

    is_yes "${BEHIND_CF:-}" && write_cf_realip

    nginx -V 2>&1 | grep -q 'http_sub_module' || {
        warn "http_sub_module not found. Installing nginx-extras..."
        apt-get install -y nginx-extras >/dev/null 2>&1 \
            && ok "nginx-extras installed." \
            || warn "Could not install nginx-extras."
    }

    local conf="${NGINX_CONF_DIR}/${PRIMARY}.conf"
    {
        echo "server {"
        echo "    listen ${HTTP_PORT};"
        echo "    server_name ${CDN_DOMAIN};"
        echo "    return 301 https://\$host\$request_uri;"
        echo "}"
        echo ""
        echo "server {"
        echo "    listen ${HTTPS_PORT} ssl;"
        echo "    server_name ${CDN_DOMAIN};"
        echo ""
        echo "    ssl_certificate     ${SSL_CERT};"
        echo "    ssl_certificate_key ${SSL_KEY};"
        echo "    ssl_protocols TLSv1.2 TLSv1.3;"
        echo "    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;"
        echo "    ssl_prefer_server_ciphers off;"
        echo "    ssl_session_cache shared:SSL:10m;"
        echo "    ssl_session_timeout 1d;"
        echo ""
        echo "    server_tokens off;"
        echo "    add_header X-Content-Type-Options nosniff always;"
        echo "    add_header X-Frame-Options SAMEORIGIN always;"
        echo "    add_header Referrer-Policy no-referrer-when-downgrade always;"
        echo "    add_header Strict-Transport-Security \"max-age=63072000; includeSubDomains\" always;"
        echo "    add_header X-XSS-Protection \"0\" always;"
        echo ""
        echo "    access_log /var/log/nginx/${PRIMARY}.access.log;"
        echo "    error_log  /var/log/nginx/${PRIMARY}.error.log;"
        echo ""
        printf '%s\n' "${LOCATIONS}"
        echo "    ${CAMO_BLOCK}"
        echo "}"
    } > "$conf"

    ok "Config written: $conf"
    if nginx -t 2>/tmp/nginx_test.log; then
        systemctl enable nginx >/dev/null 2>&1
        systemctl restart nginx
        ok "Nginx running for: ${CDN_DOMAIN}"
        echo -e "${INFO}CDN URL  : https://${CDN_DOMAIN}:${HTTPS_PORT}/${RESET}"
        echo -e "${INFO}Panel    : ${PANEL_DOMAIN}:${PANEL_PORT}${RESET}"
    else
        err "Config test failed:"; cat /tmp/nginx_test.log; return 1
    fi
}

do_install() {
    install_nginx; ensure_sqlite3; gather_inputs
    write_config || return 1; enable_persistence silent
}

# ---------------- Full Nginx Uninstall ----------------
full_uninstall() {
    echo -e "${ERR_BG} WARNING ${RESET} This will COMPLETELY remove Nginx and all GoldIP configs!"
    local CONFIRM
    ask_optional CONFIRM "Type YES to confirm full uninstall" "(anything else cancels)"
    [ "$CONFIRM" = "YES" ] || { warn "Cancelled."; return; }
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    ok "Nginx stopped and disabled."
    systemctl stop goldip-watchdog.timer 2>/dev/null || true
    systemctl disable goldip-watchdog.timer 2>/dev/null || true
    rm -f /etc/systemd/system/goldip-watchdog.timer
    rm -f /etc/systemd/system/goldip-watchdog.service
    rm -f /usr/local/bin/goldip-watchdog.sh
    ok "Watchdog removed."
    rm -rf /etc/systemd/system/nginx.service.d
    systemctl daemon-reload >/dev/null 2>&1
    apt-get purge -y nginx nginx-common nginx-full nginx-extras nginx-core 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    ok "Nginx packages removed."
    rm -rf /etc/nginx /var/log/nginx /var/www/goldip
    rm -f /var/lock/nginx.lock /run/nginx.pid 2>/dev/null || true
    ok "Nginx fully uninstalled and all configs cleaned."
}

uninstall_domain() {
    local D
    ask D "Domain config to remove" "(e.g. ex.example.com)"
    rm -f "${NGINX_CONF_DIR}/${D}.conf"
    command -v nginx >/dev/null 2>&1 && nginx -t 2>/dev/null && systemctl reload nginx \
        && ok "Config for ${D} removed." || ok "Config for ${D} removed (nginx not running)."
}

# ---------------- Service control ----------------
svc() {
    case "$1" in
        start)   systemctl start nginx   && ok "Nginx started"   || err "Start failed" ;;
        stop)    systemctl stop nginx    && ok "Nginx stopped"   || err "Stop failed" ;;
        restart) systemctl restart nginx && ok "Nginx restarted" || err "Restart failed" ;;
        reload)  nginx -t 2>/dev/null && systemctl reload nginx && ok "Nginx reloaded" \
                     || err "Reload failed (config invalid)" ;;
    esac
}

show_status() {
    systemctl is-active --quiet nginx && ok "Nginx is ACTIVE" || err "Nginx is INACTIVE"
    systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service' && {
        systemctl is-active --quiet x-ui && ok "x-ui is ACTIVE" || err "x-ui is INACTIVE"
    }
    echo -e "${INFO}--- Boot status ---${RESET}"
    printf 'nginx enabled: %s\n' "$(systemctl is-enabled nginx 2>/dev/null || echo n/a)"
    systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service' && \
        printf 'x-ui  enabled: %s\n' "$(systemctl is-enabled x-ui 2>/dev/null || echo n/a)"
    systemctl list-unit-files 2>/dev/null | grep -q '^goldip-watchdog\.timer' && \
        printf 'watchdog: %s\n' "$(systemctl is-active goldip-watchdog.timer 2>/dev/null || echo inactive)"
    echo -e "${INFO}--- nginx -t ---${RESET}"; nginx -t 2>&1
    echo -e "${INFO}--- Listening sockets ---${RESET}"
    ss -ltnp 2>/dev/null | grep nginx || warn "No nginx sockets."
}

# ---------------- Logs ----------------
colorize_error_line() {
    local line="$1"
    printf '%s' "$line" | grep -qiE '\[(error|crit|alert|emerg)\]' \
        && { echo -e "${ERR_BG} ERR ${RESET} $line"; return; }
    printf '%s' "$line" | grep -qiE '\[warn\]' \
        && { echo -e "${WARN_BG} WARN ${RESET} $line"; return; }
    printf '%s' "$line" | grep -qiE '\[notice\]' \
        && { echo -e "${OK_BG} NOTE ${RESET} $line"; return; }
    echo -e "${M3}$line${RESET}"
}
colorize_access_line() {
    local line="$1" code
    code=$(printf '%s' "$line" | grep -oE '" [1-5][0-9][0-9] ' | head -n1 | tr -dc '0-9')
    [ -n "$code" ] || code=$(printf '%s' "$line" | grep -oE ' [1-5][0-9][0-9] ' | head -n1 | tr -dc '0-9')
    case "$code" in
        5*) echo -e "${ERR_BG} ${code} ${RESET} $line" ;;
        4*) echo -e "${WARN_BG} ${code} ${RESET} $line" ;;
        2*|3*) echo -e "${OK_BG} ${code} ${RESET} $line" ;;
        *) echo -e "${M8}$line${RESET}" ;;
    esac
}
view_logs() {
    local logdir="/var/log/nginx"
    [ -d "$logdir" ] || { err "No nginx log directory."; return; }
    local -a LOGS; local f i=0
    for f in "$logdir"/*.log; do [ -f "$f" ] || continue; i=$((i+1)); LOGS[$i]="$f"; done
    [ "$i" -gt 0 ] || { warn "No log files found yet."; return; }
    echo -e "${INFO}Available logs:${RESET}"
    local n size
    for n in $(seq 1 "$i"); do
        size=$(du -h "${LOGS[$n]}" 2>/dev/null | awk '{print $1}')
        echo -e "  ${M8}${n})${RESET} ${M4}${LOGS[$n]}${RESET} ${M5}(${size:-0})${RESET}"
    done
    local PICK follow=0
    ask PICK "Log number" "(or 'f' for live-follow)"
    case "$PICK" in f|F) follow=1; ask_number PICK "Which number?" ;; esac
    case "$PICK" in ''|*[!0-9]*) err "Invalid."; return ;; esac
    { [ "$PICK" -ge 1 ] && [ "$PICK" -le "$i" ]; } || { err "Out of range."; return; }
    local target="${LOGS[$PICK]}" kind="access"
    case "$target" in *error*.log) kind="error" ;; esac
    if [ "$follow" -eq 1 ]; then
        echo -e "${INFO}Following ${target} (Ctrl+C to stop)...${RESET}"
        [ "$kind" = "error" ] \
            && tail -n 0 -f "$target" | while IFS= read -r line; do colorize_error_line "$line"; done \
            || tail -n 0 -f "$target" | while IFS= read -r line; do colorize_access_line "$line"; done
        return
    fi
    echo -e "${INFO}===== ${target} (last 50) =====${RESET}"
    [ "$kind" = "error" ] \
        && tail -n 50 "$target" | while IFS= read -r line; do colorize_error_line "$line"; done \
        || tail -n 50 "$target" | while IFS= read -r line; do colorize_access_line "$line"; done
}

# ---------------- CDN IP ranges ----------------
fetch_cloudflare_ranges() {
    local v4="" v6=""
    if command -v curl >/dev/null 2>&1; then
        v4=$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null | tr '\n' ' ')
        v6=$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null | tr '\n' ' ')
    else
        v4=$(wget -qO- --timeout=10 https://www.cloudflare.com/ips-v4 2>/dev/null | tr '\n' ' ')
        v6=$(wget -qO- --timeout=10 https://www.cloudflare.com/ips-v6 2>/dev/null | tr '\n' ' ')
    fi
    printf '%s' "$v4" | grep -q '/' \
        && { CF_V4=$(printf '%s' "$v4" | tr -s ' '); ok "Fetched CF IPv4."; } \
        || { CF_V4="$CF_V4_DEFAULT"; warn "Using built-in CF IPv4."; }
    printf '%s' "$v6" | grep -q '/' \
        && { CF_V6=$(printf '%s' "$v6" | tr -s ' '); ok "Fetched CF IPv6."; } \
        || { CF_V6="$CF_V6_DEFAULT"; warn "Using built-in CF IPv6."; }
}
fetch_arvan_ranges() {
    local v4="" url
    for url in https://www.arvancloud.ir/en/ips.txt https://www.arvancloud.ir/fa/ips.txt; do
        if command -v curl >/dev/null 2>&1; then
            v4=$(curl -fsSL --max-time 12 -A "Mozilla/5.0" "$url" 2>/dev/null | tr -d '\r')
        else
            v4=$(wget -qO- --timeout=12 -U "Mozilla/5.0" "$url" 2>/dev/null | tr -d '\r')
        fi
        printf '%s' "$v4" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' && break
    done
    v4=$(printf '%s\n' "$v4" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | sort -u | tr '\n' ' ')
    printf '%s' "$v4" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' && {
        ARVAN_V4=$(for x in $v4; do case "$x" in */*) echo "$x";; *) echo "$x/32";; esac; done | tr '\n' ' ')
        ok "Fetched ArvanCloud ranges."
    } || { ARVAN_V4="$ARVAN_V4_DEFAULT"; warn "Using built-in Arvan ranges."; }
    ARVAN_V6="$ARVAN_V6_DEFAULT"
}
write_realip() {
    local provider="$1" f hdr ranges4 ranges6
    case "$provider" in
        cloudflare)
            [ -n "$CF_V4" ] || fetch_cloudflare_ranges
            f="${NGINX_CONF_DIR}/00-cloudflare-realip.conf"
            hdr="CF-Connecting-IP"; ranges4="$CF_V4"; ranges6="$CF_V6" ;;
        arvan)
            [ -n "$ARVAN_V4" ] || fetch_arvan_ranges
            f="${NGINX_CONF_DIR}/00-arvan-realip.conf"
            hdr="X-Forwarded-For"; ranges4="$ARVAN_V4"; ranges6="$ARVAN_V6" ;;
        *) return 1 ;;
    esac
    {
        echo "# Real-IP from ${provider} (auto-generated by GoldIP)"
        for c in $ranges4; do echo "set_real_ip_from $c;"; done
        for c in $ranges6; do echo "set_real_ip_from $c;"; done
        echo "real_ip_header ${hdr};"
        echo "real_ip_recursive on;"
    } > "$f"
    nginx -t 2>/tmp/nginx_test.log \
        && ok "${provider} real-IP enabled." \
        || { warn "real-IP config rejected. Removing."; rm -f "$f"; cat /tmp/nginx_test.log; }
}
write_cf_realip() { write_realip cloudflare; }

# ---------------- Firewall ----------------
setup_firewall() {
    command -v ufw >/dev/null 2>&1 || {
        warn "ufw not found. Installing..."
        if ls ./ufw-offline/*.deb >/dev/null 2>&1; then
            dpkg -i ./ufw-offline/*.deb >/dev/null 2>&1; apt-get install -f -y >/dev/null 2>&1
        else
            apt-get update -y >/dev/null 2>&1; apt-get install -y ufw >/dev/null 2>&1
        fi
        command -v ufw >/dev/null 2>&1 || { err "ufw install failed."; return 1; }
    }

    echo -e "${INFO}CDN Provider:${RESET}"
    echo -e "  ${M1}1)${RESET} Cloudflare  ${M2}2)${RESET} ArvanCloud  ${M3}3)${RESET} Both  ${M8}4)${RESET} Custom"
    local CDN_CHOICE; ask_choice CDN_CHOICE "Selection" "1|2|3|4"
    local RANGES="" RANGES6=""
    case "$CDN_CHOICE" in
        1) fetch_cloudflare_ranges; RANGES="$CF_V4"; RANGES6="$CF_V6" ;;
        2) fetch_arvan_ranges; RANGES="$ARVAN_V4"; RANGES6="$ARVAN_V6" ;;
        3) fetch_cloudflare_ranges; fetch_arvan_ranges
           RANGES="$CF_V4 $ARVAN_V4"; RANGES6="$CF_V6 $ARVAN_V6" ;;
        4) ask RANGES "IPv4 CIDRs (space-separated)"
           ask_optional RANGES6 "IPv6 CIDRs" "(blank for none)" ;;
    esac
    [ -n "$RANGES" ] || { err "No IPv4 ranges resolved."; return 1; }

    local SSH_PORT FW_HTTPS FW_HTTP TUN_PORT FOREIGN_IP=""
    ask_port SSH_PORT "SSH port" 22
    ask_port FW_HTTPS "HTTPS port exposed to CDN" 443
    ask_port FW_HTTP  "HTTP port exposed to CDN"  80
    ask_port_optional TUN_PORT "Tunnel port (e.g. 8443)"
    [ -n "$TUN_PORT" ] && ask_optional FOREIGN_IP "Tunnel allowed from IP" "(blank = any)"

    # Auto-detect x-ui open ports from DB
    local XUI_PORTS=""
    local xdb=""
    for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do
        [ -f "$c" ] && xdb="$c" && break
    done
    if [ -n "$xdb" ] && command -v sqlite3 >/dev/null 2>&1; then
        local pport sport
        pport=$(sqlite3 "$xdb" "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" 2>/dev/null || echo "")
        [ -z "$pport" ] && pport=$(sqlite3 "$xdb" "SELECT value FROM settings WHERE key='port' LIMIT 1;" 2>/dev/null || echo "")
        sport=$(sqlite3 "$xdb" "SELECT value FROM settings WHERE key='subPort' LIMIT 1;" 2>/dev/null || echo "")
        # All inbound ports (non-CDN direct)
        local iports
        iports=$(sqlite3 "$xdb" "SELECT port FROM inbounds;" 2>/dev/null | tr '\n' ' ')
        XUI_PORTS="${pport} ${sport} ${iports}"
        XUI_PORTS=$(printf '%s' "$XUI_PORTS" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ')
        ok "Auto-detected x-ui ports: ${XUI_PORTS}"
    else
        warn "Could not auto-detect x-ui ports from DB."
    fi

    # Resolve goldip.net IPs for whitelist
    echo -e "${INFO}Resolving ${GOLDIP_TRUSTED} for whitelist...${RESET}"
    local GOLDIP_IPS
    GOLDIP_IPS=$(resolve_domain_ips "$GOLDIP_TRUSTED")
    if [ -n "$GOLDIP_IPS" ]; then
        ok "Resolved ${GOLDIP_TRUSTED}: ${GOLDIP_IPS}"
    else
        warn "Could not resolve ${GOLDIP_TRUSTED}. Will allow by domain hint only."
    fi

    [ -n "$RANGES6" ] && [ -f /etc/default/ufw ] && sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw 2>/dev/null

    warn "Resetting firewall and applying rules..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # SSH
    ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1
    ok "SSH allowed on ${SSH_PORT}/tcp"

    # CDN ranges -> HTTPS + HTTP
    local cidr
    for cidr in $RANGES; do
        ufw allow from "$cidr" to any port "$FW_HTTPS" proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port "$FW_HTTP"  proto tcp >/dev/null 2>&1
    done
    for cidr in $RANGES6; do
        ufw allow from "$cidr" to any port "$FW_HTTPS" proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port "$FW_HTTP"  proto tcp >/dev/null 2>&1
    done
    ok "CDN ranges allowed on ports ${FW_HTTPS},${FW_HTTP}"

    # Tunnel port
    if [ -n "$TUN_PORT" ]; then
        [ -n "$FOREIGN_IP" ] \
            && { ufw allow from "$FOREIGN_IP" to any port "$TUN_PORT" proto tcp >/dev/null 2>&1
                 ok "Tunnel ${TUN_PORT} from ${FOREIGN_IP}"; } \
            || { ufw allow "${TUN_PORT}/tcp" >/dev/null 2>&1
                 warn "Tunnel ${TUN_PORT} open to ANY."; }
    fi

    # goldip.net IPs -> allow ALL ports
    for ip in $GOLDIP_IPS; do
        ufw allow from "$ip" >/dev/null 2>&1
        ok "Whitelisted ${GOLDIP_TRUSTED} IP: ${ip} (all ports)"
    done

    # x-ui panel + sub + inbound ports -> allow all (needed for direct non-CDN connections)
    for p in $XUI_PORTS; do
        [ -z "$p" ] && continue
        ufw allow "${p}/tcp" >/dev/null 2>&1
        ok "x-ui port allowed: ${p}/tcp"
    done

    ufw --force enable >/dev/null 2>&1
    ok "Firewall enabled."

    command -v nginx >/dev/null 2>&1 && {
        local RIP
        case "$CDN_CHOICE" in
            1) ask_optional RIP "Restore real IPs from Cloudflare in nginx?" "[y/N]"
               is_yes "$RIP" && { write_realip cloudflare; systemctl reload nginx 2>/dev/null; } ;;
            2) ask_optional RIP "Restore real IPs from ArvanCloud in nginx?" "[y/N]"
               is_yes "$RIP" && { write_realip arvan; systemctl reload nginx 2>/dev/null; } ;;
            3) ask_optional RIP "Restore real IPs? [c=CF / a=Arvan / blank=skip]" ""
               case "$RIP" in
                   c|C) write_realip cloudflare; systemctl reload nginx 2>/dev/null ;;
                   a|A) write_realip arvan;      systemctl reload nginx 2>/dev/null ;;
               esac ;;
        esac
    }
    { [ "$CDN_CHOICE" = "1" ] || [ "$CDN_CHOICE" = "3" ]; } && {
        warn "CF only forwards: 443,2053,2083,2087,2096,8443"
        warn "Set CF SSL mode to Full (not Flexible)."
    }
    echo -e "${INFO}--- Active rules ---${RESET}"; ufw status numbered
}

firewall_status() {
    command -v ufw >/dev/null 2>&1 && ufw status verbose || warn "ufw not installed."
}

# ---------------- Watchdog ----------------
install_watchdog() {
    cat > /usr/local/bin/goldip-watchdog.sh <<'WEOF'
#!/bin/bash
for svc in nginx x-ui; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service" || continue
    systemctl is-enabled --quiet "$svc" 2>/dev/null || continue
    systemctl is-active  --quiet "$svc" 2>/dev/null || systemctl restart "$svc"
done
WEOF
    chmod +x /usr/local/bin/goldip-watchdog.sh
    cat > /etc/systemd/system/goldip-watchdog.service <<'SEOF'
[Unit]
Description=GoldIP watchdog
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/goldip-watchdog.sh
SEOF
    cat > /etc/systemd/system/goldip-watchdog.timer <<'TEOF'
[Unit]
Description=GoldIP watchdog timer
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Persistent=true
[Install]
WantedBy=timers.target
TEOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now goldip-watchdog.timer >/dev/null 2>&1
    ok "Watchdog installed (60s interval)."
}

# ---------------- Persistence ----------------
enable_persistence() {
    local mode="${1:-}"
    if command -v nginx >/dev/null 2>&1; then
        systemctl enable nginx >/dev/null 2>&1 && ok "Nginx enabled on boot." || warn "Could not enable nginx."
        mkdir -p /etc/systemd/system/nginx.service.d
        local after="network-online.target"
        systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service' && \
            after="network-online.target x-ui.service"
        cat > /etc/systemd/system/nginx.service.d/goldip.conf <<DEOF
[Unit]
After=${after}
Wants=network-online.target
[Service]
Restart=on-failure
RestartSec=3s
DEOF
        ok "Nginx drop-in written."
    else
        warn "Nginx not installed."
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        systemctl enable x-ui >/dev/null 2>&1 && ok "x-ui enabled on boot." || warn "Could not enable x-ui."
        mkdir -p /etc/systemd/system/x-ui.service.d
        cat > /etc/systemd/system/x-ui.service.d/goldip.conf <<'XEOF'
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Restart=on-failure
RestartSec=3s
XEOF
        ok "x-ui drop-in written."
    else
        warn "x-ui.service not found."
    fi
    systemctl daemon-reload >/dev/null 2>&1; ok "systemd reloaded."
    [ "$mode" = "silent" ] && return
    systemctl list-unit-files 2>/dev/null | grep -q '^goldip-watchdog\.timer' \
        && ok "Watchdog already active." \
        || { local WD; ask_optional WD "Install 1-min watchdog?" "[y/N]"; is_yes "$WD" && install_watchdog; }
}

# ---------------- Menu ----------------
menu() {
    while true; do
        clear
        echo -e "${TITLE}"; header; echo -e "${RESET}"
        echo -e "  ${M1}1)${RESET}  Install / Config website"
        echo -e "  ${M9}2)${RESET}  Start Nginx"
        echo -e "  ${M3}3)${RESET}  Stop Nginx"
        echo -e "  ${M4}4)${RESET}  Restart Nginx"
        echo -e "  ${M5}5)${RESET}  Reload Nginx"
        echo -e "  ${M7}6)${RESET}  Status"
        echo -e "  ${M8}7)${RESET}  View logs"
        echo -e "  ${M2}8)${RESET}  Remove domain config"
        echo -e "  ${M11}9)${RESET}  Setup firewall"
        echo -e "  ${M10}10)${RESET} Firewall status"
        echo -e "  ${M12}11)${RESET} Fix auto-start (persistence)"
        echo -e "  ${M6}12)${RESET} FULL Nginx uninstall + cleanup"
        echo -e "  ${M6}0)${RESET}  Exit"
        local CH; ask_optional CH "Choose"
        case "$CH" in
            1)  do_install ;;
            2)  svc start ;;
            3)  svc stop ;;
            4)  svc restart ;;
            5)  svc reload ;;
            6)  show_status ;;
            7)  view_logs ;;
            8)  uninstall_domain ;;
            9)  setup_firewall ;;
            10) firewall_status ;;
            11) enable_persistence ;;
            12) full_uninstall ;;
            0)  exit 0 ;;
            *)  err "Invalid choice." ;;
        esac
        local _; ask_optional _ "Press Enter to continue..."
    done
}

# ---------------- Entry ----------------
# (GOLDIP_TEST_MODE lets this file be `source`d for automated testing
#  without launching the interactive menu or requiring root. It is never
#  set in normal/production use.)
if [ "${GOLDIP_TEST_MODE:-0}" != "1" ]; then
    require_root
    menu
fi
