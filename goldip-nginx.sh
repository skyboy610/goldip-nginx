#!/bin/bash
# ============================================================
#  GoldIP Nginx Camouflage Installer & Manager
# ============================================================
#  Installs Nginx in front of a local service (Xray/3x-ui),
#  serves a real camouflage site on "/", and proxies a secret
#  path to the local service. Supports OFFLINE install for
#  Iran servers (place .deb files in ./nginx-offline/).
#
#  Behaviour:
#   - Questions are cyan; defaults/examples are white.
#   - Red / yellow / green are reserved for status messages.
#   - Any wrong answer re-asks on the spot (no full restart).
#   - sqlite3 is auto-installed when needed.
#   - Cloudflare CDN ranges (v4+v6) supported in firewall.
#   - nginx + x-ui auto-start and self-heal after reboot.
#   - Color-coded log viewer that auto-discovers logs.
# ============================================================

set -uo pipefail

# ---------------- Colors ----------------
RESET='\033[0m'
# menu line colors (each unique, never white)
M1='\033[1;36m'   # cyan
M2='\033[1;35m'   # magenta
M3='\033[1;34m'   # blue
M4='\033[1;32m'   # green
M5='\033[1;33m'   # yellow
M6='\033[1;31m'   # red
M7='\033[1;95m'   # bright magenta
M8='\033[1;96m'   # bright cyan
M9='\033[1;92m'   # bright green
M10='\033[1;93m'  # bright yellow
M11='\033[1;94m'  # bright blue
M12='\033[1;91m'  # bright red
TITLE='\033[1;36m'
PROMPT='\033[1;96m'  # bright cyan - question text (never red/yellow/green)
HINT='\033[1;97m'    # bright white - defaults/examples inside a question
INFO='\033[1;34m'    # blue - info lines

# message badges: colored background + white text (errors/status only)
OK_BG='\033[42m\033[97m'    # green bg
WARN_BG='\033[43m\033[97m'  # yellow bg
ERR_BG='\033[41m\033[97m'   # red bg

ok()   { echo -e "${OK_BG} OK ${RESET} $1"; }
warn() { echo -e "${WARN_BG} WARN ${RESET} $1"; }
err()  { echo -e "${ERR_BG} ERROR ${RESET} $1"; }

NGINX_CONF_DIR="/etc/nginx/conf.d"
CAMO_ROOT="/var/www/goldip"

# ---------------- CDN IP ranges ----------------
# Cloudflare official ranges (fallback if live fetch fails)
CF_V4_DEFAULT="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF_V6_DEFAULT="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
# ArvanCloud CDN edge ranges - official list from www.arvancloud.ir/en/ips.txt
# (baked fallback; the script also live-fetches the latest at runtime).
ARVAN_V4_DEFAULT="178.131.120.48/28 185.143.232.0/22 185.215.232.0/22 188.229.116.16/30 2.144.3.128/28 37.32.16.0/27 37.32.17.0/27 37.32.18.0/27 37.32.19.0/27 78.157.36.112/28 94.101.182.0/27 94.101.183.0/28"
ARVAN_V6_DEFAULT=""

CF_V4=""
CF_V6=""
ARVAN_V4=""
ARVAN_V6=""

# ---------------- Input helpers (re-ask on bad input) ----------------
# ask <var> <question> [white-hint]            -> required, non-empty
ask() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans
    while true; do
        if [ -n "$__hint" ]; then
            echo -e "${PROMPT}${__q} ${HINT}${__hint}${PROMPT}:${RESET}"
        else
            echo -e "${PROMPT}${__q}:${RESET}"
        fi
        read -r __ans
        [ -n "$__ans" ] && { printf -v "$__var" '%s' "$__ans"; return 0; }
        warn "This field can't be empty. Please try again."
    done
}

# ask_optional <var> <question> [white-hint]   -> blank allowed
ask_optional() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans
    if [ -n "$__hint" ]; then
        echo -e "${PROMPT}${__q} ${HINT}${__hint}${PROMPT}:${RESET}"
    else
        echo -e "${PROMPT}${__q}:${RESET}"
    fi
    read -r __ans
    printf -v "$__var" '%s' "$__ans"
}

# ask_number <var> <question> [white-hint]     -> required integer
ask_number() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans
    while true; do
        if [ -n "$__hint" ]; then
            echo -e "${PROMPT}${__q} ${HINT}${__hint}${PROMPT}:${RESET}"
        else
            echo -e "${PROMPT}${__q}:${RESET}"
        fi
        read -r __ans
        case "$__ans" in
            ''|*[!0-9]*) warn "Must be a number. Please try again."; continue ;;
        esac
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}

# ask_port <var> <question> <default>          -> integer 1-65535, default on blank
ask_port() {
    local __var="$1" __q="$2" __def="$3" __ans
    while true; do
        echo -e "${PROMPT}${__q} ${HINT}[${__def}]${PROMPT}:${RESET}"
        read -r __ans
        [ -n "$__ans" ] || __ans="$__def"
        case "$__ans" in
            ''|*[!0-9]*) warn "Port must be a number. Please try again."; continue ;;
        esac
        if [ "$__ans" -lt 1 ] || [ "$__ans" -gt 65535 ]; then
            warn "Port out of range (1-65535). Please try again."; continue
        fi
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}

# ask_port_optional <var> <question>           -> integer or blank
ask_port_optional() {
    local __var="$1" __q="$2" __ans
    while true; do
        echo -e "${PROMPT}${__q} ${HINT}(blank to skip)${PROMPT}:${RESET}"
        read -r __ans
        [ -z "$__ans" ] && { printf -v "$__var" '%s' ""; return 0; }
        case "$__ans" in *[!0-9]*) warn "Port must be a number. Please try again."; continue ;; esac
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}

# ask_file <var> <question>                    -> existing file, re-asks
ask_file() {
    local __var="$1" __q="$2" __ans
    while true; do
        echo -e "${PROMPT}${__q}:${RESET}"
        read -r __ans
        if [ -z "$__ans" ]; then warn "Path can't be empty. Please try again."; continue; fi
        if [ ! -f "$__ans" ]; then err "File not found: $__ans"; warn "Please try again."; continue; fi
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}

# ask_choice <var> <question> <valid|regex>    -> e.g. "1|2|3"
ask_choice() {
    local __var="$1" __q="$2" __valid="$3" __ans
    while true; do
        echo -e "${PROMPT}${__q} ${HINT}[${__valid//|//}]${PROMPT}:${RESET}"
        read -r __ans
        if printf '%s' "$__ans" | grep -qiE "^(${__valid})$"; then
            printf -v "$__var" '%s' "$__ans"; return 0
        fi
        warn "Invalid choice. Allowed: ${__valid//|/, }. Please try again."
    done
}

# yes/no helper -> returns 0 for yes
is_yes() { case "$1" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac; }

# ---------------- Header ----------------
header() {
cat <<'EOF'
==========================================================
   ____       _     _ ___ ____
  / ___| ___ | | __| |_ _|  _ \
 | |  _ / _ \| |/ _` || || |_) |
 | |_| | (_) | | (_| || ||  __/
  \____|\___/|_|\__,_|___|_|
         N G I N X   C A M O U F L A G E
==========================================================
EOF
}

# ---------------- Root check ----------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Run this script as root."
        exit 1
    fi
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
    if command -v sqlite3 >/dev/null 2>&1; then
        ok "sqlite3 installed."
        return 0
    fi
    warn "Could not install sqlite3 (auto-build from x-ui DB will be unavailable)."
    warn "Offline: place sqlite3 .deb in ./sqlite-offline/ next to this script."
    return 1
}

# ---------------- Install Nginx ----------------
install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        ok "Nginx already installed ($(nginx -v 2>&1 | sed 's#.*/##'))."
        return 0
    fi

    warn "Nginx not found. Installing..."

    if ls ./nginx-offline/*.deb >/dev/null 2>&1; then
        warn "Installing from local .deb packages (offline mode)..."
        dpkg -i ./nginx-offline/*.deb >/dev/null 2>&1
        apt-get install -f -y >/dev/null 2>&1
        if command -v nginx >/dev/null 2>&1; then
            ok "Nginx installed from local packages."
        else
            err "Offline install failed. Missing dependencies in ./nginx-offline/."
            exit 1
        fi
    else
        if apt-get update -y >/dev/null 2>&1 && apt-get install -y nginx >/dev/null 2>&1; then
            ok "Nginx installed from repository."
        else
            err "Repository install failed. On Iran servers, download .deb on a"
            err "foreign server and place them in ./nginx-offline/ next to this script:"
            echo -e "${INFO}  apt-get download nginx nginx-common nginx-core${RESET}"
            exit 1
        fi
    fi
}

# ---------------- Build a location block ----------------
# args: <type: upgrade|xhttp> <path> <port>
make_location() {
    local t="$1" p="$2" port="$3"
    if [ "$t" = "xhttp" ]; then
        printf '    location %s {\n        proxy_pass http://127.0.0.1:%s;\n        proxy_http_version 1.1;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_buffering off;\n        proxy_request_buffering off;\n        proxy_read_timeout 300s;\n        proxy_send_timeout 300s;\n    }\n' "$p" "$port"
    else
        printf '    location %s {\n        proxy_pass http://127.0.0.1:%s;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection "upgrade";\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_read_timeout 300s;\n        proxy_send_timeout 300s;\n    }\n' "$p" "$port"
    fi
}

# ---------------- Find a free local port ----------------
# Uses globals: USED_PORTS (listening), TAKEN_PORTS (already assigned this run)
free_port() {
    local p
    for p in $(seq 20000 29999); do
        case " $USED_PORTS " in *" $p "*) continue ;; esac
        case " $TAKEN_PORTS " in *" $p "*) continue ;; esac
        echo "$p"; return 0
    done
    return 1
}

# ---------------- Safe JSON surgery on one inbound's stream_settings ----------------
# Args: <stream_settings_json> <domain> <https_port> <set_extproxy:1|0>
# Prints transformed compact JSON on stdout.
# Sets security=none, drops tlsSettings/realitySettings (nginx terminates TLS),
# and (optionally) writes externalProxy so x-ui auto-generates client links
# pointing at domain:https_port with forceTls=tls. Requires python3.
transform_inbound_json() {
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import json, sys
raw, domain, hport, setep = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    ss = json.loads(raw)
except Exception:
    sys.exit(2)
if not isinstance(ss, dict):
    sys.exit(2)
# nginx terminates TLS -> the real listener must speak plain http
ss["security"] = "none"
for k in ("tlsSettings", "realitySettings", "externalProxySettings", "externalProxy"):
    ss.pop(k, None)
if setep == "1":
    try:
        port = int(hport)
    except ValueError:
        port = 443
    ss["externalProxy"] = [{
        "forceTls": "tls",
        "dest": domain,
        "port": port,
        "remark": ""
    }]
json.dump(ss, sys.stdout, separators=(",", ":"), ensure_ascii=False)
PYEOF
}

# ---------------- Fully automatic: build locations from x-ui DB ----------------
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

    local -a IN_ID IN_PORT IN_NET IN_PATH IN_SS
    local idx=0 id port ss net rawpath path
    while IFS='|' read -r id port ss; do
        [ -n "$port" ] || continue
        case "$id" in ''|*[!0-9]*) continue ;; esac
        case "$port" in *[!0-9]*) continue ;; esac
        net=$(printf '%s' "$ss" | grep -oE '"network"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        rawpath=$(printf '%s' "$ss" | grep -oE '"path"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        path=${rawpath%%\?*}
        idx=$((idx+1))
        IN_ID[$idx]="$id"
        IN_PORT[$idx]="$port"
        IN_NET[$idx]="${net:-unknown}"
        IN_PATH[$idx]="$path"
        IN_SS[$idx]="$ss"
    done < <(sqlite3 -separator '|' "$db" "SELECT id, port, replace(replace(stream_settings, char(10), ' '), char(13), ' ') FROM inbounds;" 2>/dev/null)

    [ "$idx" -ge 1 ] || { warn "No inbounds found in database."; return 1; }

    echo -e "${INFO}Inbounds found:${RESET}"
    local n
    for n in $(seq 1 "$idx"); do
        echo -e "  ${M8}${n})${RESET} ${M4}port ${IN_PORT[$n]}${RESET} | ${M5}${IN_NET[$n]}${RESET} | ${M1}${IN_PATH[$n]:-(no path)}${RESET}"
    done
    echo -e "${INFO}Leave tunnel inbounds OUT - they stay direct on 0.0.0.0 and are not touched.${RESET}"
    ask SEL "Which inbounds go BEHIND Nginx?" "(comma-separated, e.g. 1,3,4)"

    LOCATIONS=""
    local added=0 skipped=0
    local SQL_UPDATES=""
    local TLSOFF="stream_settings=replace(replace(stream_settings,'\"security\": \"tls\"','\"security\":\"none\"'),'\"security\":\"tls\"','\"security\":\"none\"')"
    USED_PORTS=$(ss -ltn 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': ' | tr '\n' ' ')
    TAKEN_PORTS=""
    SEEN_PATHS=""

    # Can we do safe JSON surgery? (needed for clean externalProxy handling)
    local HAVE_PY=0
    command -v python3 >/dev/null 2>&1 && HAVE_PY=1

    # Offer to auto-write External Proxy so the panel generates ready-to-share links
    # (dest=domain, port=HTTPS, forceTls=tls). The real listener stays 127.0.0.1 + security=none.
    local EP_AUTO=0 EPASK
    if [ "$HAVE_PY" = "1" ]; then
        ask_optional EPASK "Auto-set External Proxy on selected inbounds so client links are ready to hand out (dest=${PRIMARY}, port=${HTTPS_PORT}, TLS)?" "[Y/n]"
        case "$EPASK" in [nN]|[nN][oO]) EP_AUTO=0 ;; *) EP_AUTO=1 ;; esac
    else
        warn "python3 not found: External Proxy can't be auto-configured."
        warn "Falling back to TLS-off only. Set External Proxy manually in the panel if you need pre-filled links."
    fi

    local sel ltype fport
    for sel in $(printf '%s' "$SEL" | tr ',' ' '); do
        case "$sel" in ''|*[!0-9]*) warn "Ignore invalid selection '$sel'."; continue ;; esac
        if [ "$sel" -lt 1 ] || [ "$sel" -gt "$idx" ]; then
            warn "Ignore out-of-range selection '$sel'."; continue
        fi
        port="${IN_PORT[$sel]}"; net="${IN_NET[$sel]}"; path="${IN_PATH[$sel]}"

        case "$net" in
            ws|httpupgrade) ltype="upgrade" ;;
            xhttp|splithttp) ltype="xhttp" ;;
            *) warn "Skip #${sel} (port ${port}): transport '${net}' can't be proxied via Nginx."
               skipped=$((skipped+1)); continue ;;
        esac

        if [ -z "$path" ] || [ "$path" = "/" ]; then
            warn "Skip #${sel} (port ${port}): path '${path:-empty}' needs a unique non-root value."
            skipped=$((skipped+1)); continue
        fi
        case " $SEEN_PATHS " in
            *" $path "*) warn "Skip #${sel} (port ${port}): path '${path}' duplicate."
                         skipped=$((skipped+1)); continue ;;
        esac
        SEEN_PATHS="${SEEN_PATHS} ${path}"

        # Decide the real local listener port (move off 443/80 if it collides with Nginx)
        fport="$port"
        if [ "$port" = "$HTTPS_PORT" ] || [ "$port" = "$HTTP_PORT" ]; then
            fport=$(free_port) || { err "No free local port available."; return 1; }
            warn "Port ${port} conflicts with Nginx -> moving inbound to 127.0.0.1:${fport}"
        fi
        TAKEN_PORTS="${TAKEN_PORTS} ${fport}"

        local id newjson
        id="${IN_ID[$sel]}"
        if [ "$HAVE_PY" = "1" ]; then
            # Safe JSON surgery: security=none, drop tlsSettings, (opt) set externalProxy.
            if newjson=$(transform_inbound_json "${IN_SS[$sel]}" "$PRIMARY" "$HTTPS_PORT" "$EP_AUTO"); then
                newjson=${newjson//\'/\'\'}   # escape single quotes for SQL literal
                SQL_UPDATES="${SQL_UPDATES}UPDATE inbounds SET listen='127.0.0.1', port=${fport}, stream_settings='${newjson}' WHERE id=${id};
"
                if [ "$EP_AUTO" = "1" ]; then
                    ok "Added #${sel} ${net} -> ${path} (127.0.0.1:${fport}) + External Proxy ${PRIMARY}:${HTTPS_PORT}"
                else
                    ok "Added #${sel} ${net} -> ${path} (127.0.0.1:${fport}) TLS off"
                fi
            else
                warn "Could not parse inbound #${sel} JSON -> using TLS-off fallback."
                SQL_UPDATES="${SQL_UPDATES}UPDATE inbounds SET listen='127.0.0.1', port=${fport}, ${TLSOFF} WHERE id=${id};
"
                ok "Added #${sel} ${net} -> ${path} (127.0.0.1:${fport})"
            fi
        else
            # No python3: best-effort TLS-off via string replace.
            if printf '%s' "${IN_SS[$sel]}" | grep -q '"externalProxy"'; then
                warn "Inbound #${sel} keeps its External Proxy; verify dest=${PRIMARY} port=${HTTPS_PORT} forceTls=tls in the panel."
            fi
            SQL_UPDATES="${SQL_UPDATES}UPDATE inbounds SET listen='127.0.0.1', port=${fport}, ${TLSOFF} WHERE id=${id};
"
            ok "Added #${sel} ${net} -> ${path} (127.0.0.1:${fport})"
        fi

        LOCATIONS="${LOCATIONS}
$(make_location "$ltype" "$path" "$fport")"
        added=$((added+1))
    done

    echo -e "${INFO}Selected: ${added} added, ${skipped} skipped. Unselected inbounds untouched.${RESET}"
    [ "$added" -ge 1 ] || return 1

    if [ -n "$SQL_UPDATES" ]; then
        echo -e "${WARN_BG} ACTION ${RESET} Apply listen=127.0.0.1 (and TLS off) to the SELECTED inbounds now?"
        warn "A backup is made first, then x-ui restarts. Unselected (tunnel) inbounds are NOT changed."
        local AP
        ask_optional AP "Apply now?" "[y/N]"
        if is_yes "$AP"; then
            local bak
            bak="${db}.bak.$(date +%s)"
            cp "$db" "$bak" && ok "DB backed up: $bak" || { err "Backup failed - aborting DB change."; return 0; }
            if printf '%s' "$SQL_UPDATES" | sqlite3 "$db" 2>/tmp/sql_err.log; then
                ok "Database updated."
                if systemctl restart x-ui 2>/dev/null || x-ui restart 2>/dev/null; then
                    ok "x-ui restarted."
                else
                    warn "Could not auto-restart x-ui. Restart it manually: x-ui restart"
                fi
            else
                err "DB update failed; restoring backup."
                cp "$bak" "$db"
                cat /tmp/sql_err.log
            fi
        else
            warn "Skipped DB change. Selected inbounds must listen on 127.0.0.1 manually,"
            warn "otherwise they stay public and bypass Nginx."
        fi
    fi
    return 0
}

# ---------------- Gather inputs ----------------
gather_inputs() {
    ask DOMAIN "Domain" "(e.g. ex.example.com - space/comma separates multiple)"
    DOMAIN=$(printf '%s' "$DOMAIN" | tr ',' ' ' | tr -s ' ' | sed -E 's/^ +| +$//g')
    PRIMARY=$(printf '%s' "$DOMAIN" | awk '{print $1}')

    ask_port HTTPS_PORT "HTTPS listen port" 443
    ask_port HTTP_PORT  "HTTP listen port"  80

    ask_file SSL_CERT "Full path to SSL certificate (cert.pem / fullchain.pem)"
    ask_file SSL_KEY  "Full path to SSL private key (key.pem / privkey.pem)"

    ask_optional BEHIND_CF "Is this server behind Cloudflare CDN? (restore real visitor IP)" "[y/N]"

    LOCATIONS=""
    echo -e "${INFO}Inbound configuration:${RESET}"
    echo -e "  ${M1}1)${RESET} ${M4}Fully automatic (read & configure from x-ui database)${RESET}"
    echo -e "  ${M2}2)${RESET} ${M5}Manual entry${RESET}"
    ask_choice DISC "Selection" "1|2"

    if [ "$DISC" = "1" ] && auto_build_locations; then
        ok "Locations built automatically from database."
    else
        [ "$DISC" = "1" ] && warn "Auto-build unavailable - switching to manual entry."
        ask_number NIN "How many inbounds to add to Nginx?"

        local i=1
        while [ "$i" -le "$NIN" ]; do
            echo -e "${INFO}--- Inbound #${i} ---${RESET}"
            ask P_PATH "Path" "(e.g. /ws${i})"
            [ "${P_PATH:0:1}" = "/" ] || P_PATH="/$P_PATH"
            ask_number P_PORT "Local Xray port (127.0.0.1:PORT)"

            echo -e "${INFO}Transport type:${RESET}"
            echo -e "  ${M1}1)${RESET} ${M4}WebSocket (ws)${RESET}"
            echo -e "  ${M2}2)${RESET} ${M5}HTTPUpgrade${RESET}"
            echo -e "  ${M3}3)${RESET} ${M7}XHTTP (splithttp)${RESET}"
            ask_choice P_TYPE "Selection" "1|2|3"

            case "$P_TYPE" in
                1|2) LOCATIONS="${LOCATIONS}
$(make_location upgrade "$P_PATH" "$P_PORT")" ;;
                3)   LOCATIONS="${LOCATIONS}
$(make_location xhttp "$P_PATH" "$P_PORT")" ;;
            esac
            i=$((i + 1))
        done
    fi

    echo -e "${INFO}Camouflage site type:${RESET}"
    echo -e "  ${M1}1)${RESET} ${M4}Reverse-proxy to an existing website${RESET}"
    echo -e "  ${M2}2)${RESET} ${M5}Serve a local HTML file${RESET}"
    ask_choice CAMO "Selection" "1|2"

    if [ "$CAMO" = "1" ]; then
        ask PROXY_URL "Website URL to proxy" "(e.g. https://example.com - avoid sites with bot protection)"
        PROXY_HOST=$(printf '%s' "$PROXY_URL" | sed -E 's#^https?://##; s#/.*##')
        CAMO_BLOCK="location / {
        proxy_pass ${PROXY_URL};
        proxy_set_header Host ${PROXY_HOST};
        proxy_ssl_server_name on;
    }"
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

# ---------------- Write config ----------------
write_config() {
    mkdir -p "$NGINX_CONF_DIR"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null

    if is_yes "${BEHIND_CF:-}"; then
        write_cf_realip
    fi

    local conf="${NGINX_CONF_DIR}/${PRIMARY}.conf"
    cat > "$conf" <<EOF
server {
    listen ${HTTP_PORT};
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${HTTPS_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;

    access_log /var/log/nginx/${PRIMARY}.access.log;
    error_log  /var/log/nginx/${PRIMARY}.error.log;
${LOCATIONS}
    ${CAMO_BLOCK}
}
EOF

    ok "Config written: $conf"

    if nginx -t 2>/tmp/nginx_test.log; then
        systemctl enable nginx >/dev/null 2>&1
        systemctl restart nginx
        ok "Nginx running for: ${DOMAIN}"
        echo -e "${INFO}Camouflage  : ${RESET}https://${PRIMARY}:${HTTPS_PORT}/"
        warn "Ensure each proxied inbound listens on 127.0.0.1 with a unique path."
    else
        err "Config test failed:"
        cat /tmp/nginx_test.log
        warn "Fix the reported line and run install again (your inputs were not lost server-side)."
        return 1
    fi
}

do_install() {
    install_nginx
    ensure_sqlite3
    gather_inputs
    write_config || return 1
    enable_persistence silent
}

# ---------------- Service control ----------------
svc() {
    case "$1" in
        start)   systemctl start nginx   && ok "Nginx started"   || err "Start failed" ;;
        stop)    systemctl stop nginx    && ok "Nginx stopped"   || err "Stop failed" ;;
        restart) systemctl restart nginx && ok "Nginx restarted" || err "Restart failed" ;;
        reload)  nginx -t 2>/dev/null && systemctl reload nginx && ok "Nginx reloaded" || err "Reload failed (config invalid)" ;;
    esac
}

show_status() {
    if systemctl is-active --quiet nginx; then
        ok "Nginx is ACTIVE"
    else
        err "Nginx is INACTIVE"
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        if systemctl is-active --quiet x-ui; then
            ok "x-ui is ACTIVE"
        else
            err "x-ui is INACTIVE"
        fi
    fi
    echo -e "${INFO}--- boot status ---${RESET}"
    printf 'nginx enabled: %s\n' "$(systemctl is-enabled nginx 2>/dev/null || echo n/a)"
    systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service' && \
        printf 'x-ui  enabled: %s\n' "$(systemctl is-enabled x-ui 2>/dev/null || echo n/a)"
    if systemctl list-unit-files 2>/dev/null | grep -q '^goldip-watchdog\.timer'; then
        printf 'watchdog timer: %s\n' "$(systemctl is-active goldip-watchdog.timer 2>/dev/null || echo inactive)"
    fi
    echo -e "${INFO}--- nginx -t ---${RESET}"
    nginx -t 2>&1
    echo -e "${INFO}--- listening sockets ---${RESET}"
    ss -ltnp 2>/dev/null | grep nginx || warn "No nginx sockets found."
}

# ---------------- Color-coded logs ----------------
colorize_error_line() {
    local line="$1"
    if printf '%s' "$line" | grep -qiE '\[(error|crit|alert|emerg)\]'; then
        echo -e "${ERR_BG} ERR  ${RESET} $line"
    elif printf '%s' "$line" | grep -qiE '\[warn\]'; then
        echo -e "${WARN_BG} WARN ${RESET} $line"
    elif printf '%s' "$line" | grep -qiE '\[notice\]'; then
        echo -e "${OK_BG} NOTE ${RESET} $line"
    else
        echo -e "${M3}$line${RESET}"
    fi
}

colorize_access_line() {
    local line="$1" code
    code=$(printf '%s' "$line" | grep -oE '" [1-5][0-9][0-9] ' | head -n1 | tr -dc '0-9')
    [ -n "$code" ] || code=$(printf '%s' "$line" | grep -oE ' [1-5][0-9][0-9] ' | head -n1 | tr -dc '0-9')
    case "$code" in
        5*) echo -e "${ERR_BG} ${code} ${RESET} $line" ;;
        4*) echo -e "${WARN_BG} ${code} ${RESET} $line" ;;
        2*|3*) echo -e "${OK_BG} ${code} ${RESET} $line" ;;
        1*) echo -e "${M3}[${code}]${RESET} $line" ;;
        *) echo -e "${M8}$line${RESET}" ;;
    esac
}

view_logs() {
    local logdir="/var/log/nginx"
    if [ ! -d "$logdir" ]; then
        err "No nginx log directory at $logdir"
        return
    fi

    local -a LOGS
    local f i=0
    for f in "$logdir"/*.log; do
        [ -f "$f" ] || continue
        i=$((i+1))
        LOGS[$i]="$f"
    done

    if [ "$i" -eq 0 ]; then
        warn "No log files found in $logdir yet (no traffic / fresh install)."
        return
    fi

    echo -e "${INFO}Available nginx logs:${RESET}"
    local n size
    for n in $(seq 1 "$i"); do
        size=$(du -h "${LOGS[$n]}" 2>/dev/null | awk '{print $1}')
        echo -e "  ${M8}${n})${RESET} ${M4}${LOGS[$n]}${RESET} ${M5}(${size:-0})${RESET}"
    done

    local PICK follow=0
    ask PICK "Pick a log number to view" "(or 'f' then a number to live-follow)"
    case "$PICK" in
        f|F) follow=1; ask_number PICK "Which number to follow?" ;;
    esac
    case "$PICK" in ''|*[!0-9]*) err "Invalid choice."; return ;; esac
    if [ "$PICK" -lt 1 ] || [ "$PICK" -gt "$i" ]; then
        err "Out of range."; return
    fi

    local target="${LOGS[$PICK]}"
    local kind="access"
    case "$target" in *error*.log) kind="error" ;; esac

    if [ "$follow" -eq 1 ]; then
        echo -e "${INFO}Live following ${target} (Ctrl+C to stop)...${RESET}"
        if [ "$kind" = "error" ]; then
            tail -n 0 -f "$target" | while IFS= read -r line; do colorize_error_line "$line"; done
        else
            tail -n 0 -f "$target" | while IFS= read -r line; do colorize_access_line "$line"; done
        fi
        return
    fi

    echo -e "${INFO}===== ${target} (last 40) =====${RESET}"
    if [ "$kind" = "error" ]; then
        tail -n 40 "$target" | while IFS= read -r line; do colorize_error_line "$line"; done
    else
        tail -n 40 "$target" | while IFS= read -r line; do colorize_access_line "$line"; done
    fi
}

# ---------------- Cloudflare real-IP restore ----------------
fetch_cloudflare_ranges() {
    local v4="" v6=""
    if command -v curl >/dev/null 2>&1; then
        v4=$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null | tr '\n' ' ')
        v6=$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null | tr '\n' ' ')
    elif command -v wget >/dev/null 2>&1; then
        v4=$(wget -qO- --timeout=10 https://www.cloudflare.com/ips-v4 2>/dev/null | tr '\n' ' ')
        v6=$(wget -qO- --timeout=10 https://www.cloudflare.com/ips-v6 2>/dev/null | tr '\n' ' ')
    fi
    if printf '%s' "$v4" | grep -q '/'; then
        CF_V4=$(printf '%s' "$v4" | tr -s ' ')
        ok "Fetched live Cloudflare IPv4 ranges."
    else
        CF_V4="$CF_V4_DEFAULT"
        warn "Live fetch failed - using built-in Cloudflare IPv4 ranges."
    fi
    if printf '%s' "$v6" | grep -q '/'; then
        CF_V6=$(printf '%s' "$v6" | tr -s ' ')
        ok "Fetched live Cloudflare IPv6 ranges."
    else
        CF_V6="$CF_V6_DEFAULT"
        warn "Live fetch failed - using built-in Cloudflare IPv6 ranges."
    fi
}

fetch_arvan_ranges() {
    local v4="" url
    for url in https://www.arvancloud.ir/en/ips.txt https://www.arvancloud.ir/fa/ips.txt; do
        if command -v curl >/dev/null 2>&1; then
            v4=$(curl -fsSL --max-time 12 -A "Mozilla/5.0" "$url" 2>/dev/null | tr -d '\r')
        elif command -v wget >/dev/null 2>&1; then
            v4=$(wget -qO- --timeout=12 -U "Mozilla/5.0" "$url" 2>/dev/null | tr -d '\r')
        fi
        printf '%s' "$v4" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' && break
    done
    # keep only v4 (optionally /CIDR) entries, join with spaces
    v4=$(printf '%s\n' "$v4" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | sort -u | tr '\n' ' ')
    if printf '%s' "$v4" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        # add /32 to bare IPs so ufw accepts them uniformly
        ARVAN_V4=$(for x in $v4; do case "$x" in */*) echo "$x" ;; *) echo "$x/32" ;; esac; done | tr '\n' ' ')
        ok "Fetched live ArvanCloud ranges ($(printf '%s' "$ARVAN_V4" | wc -w) entries)."
    else
        ARVAN_V4="$ARVAN_V4_DEFAULT"
        warn "Live fetch failed - using built-in ArvanCloud ranges."
    fi
    ARVAN_V6="$ARVAN_V6_DEFAULT"
}

# write_realip <provider>  (provider = cloudflare | arvan)
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
        echo "# Restore real client IP from ${provider} (auto-generated by GoldIP)"
        for c in $ranges4; do echo "set_real_ip_from $c;"; done
        for c in $ranges6; do echo "set_real_ip_from $c;"; done
        echo "real_ip_header ${hdr};"
        echo "real_ip_recursive on;"
    } > "$f"
    if nginx -t 2>/tmp/nginx_test.log; then
        ok "${provider} real-IP restore enabled ($f)."
    else
        warn "real-IP config rejected by nginx - removing it."
        rm -f "$f"
        cat /tmp/nginx_test.log
    fi
}

# Backward-compatible wrapper (used by the install-time BEHIND_CF prompt)
write_cf_realip() { write_realip cloudflare; }

# ---------------- Firewall ----------------
setup_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        warn "ufw not found. Installing..."
        if ls ./ufw-offline/*.deb >/dev/null 2>&1; then
            dpkg -i ./ufw-offline/*.deb >/dev/null 2>&1; apt-get install -f -y >/dev/null 2>&1
        else
            apt-get update -y >/dev/null 2>&1 && apt-get install -y ufw >/dev/null 2>&1
        fi
        command -v ufw >/dev/null 2>&1 || { err "ufw install failed."; return 1; }
    fi

    echo -e "${INFO}Which CDN sits in front of this server?${RESET}"
    echo -e "  ${M1}1)${RESET} ${M4}Cloudflare${RESET}"
    echo -e "  ${M2}2)${RESET} ${M5}ArvanCloud${RESET}"
    echo -e "  ${M3}3)${RESET} ${M7}Both (Cloudflare + ArvanCloud)${RESET}"
    echo -e "  ${M8}4)${RESET} ${M8}Custom CIDRs${RESET}"
    local CDN_CHOICE
    ask_choice CDN_CHOICE "Selection" "1|2|3|4"

    local RANGES="" RANGES6=""
    case "$CDN_CHOICE" in
        1)  fetch_cloudflare_ranges
            RANGES="$CF_V4"; RANGES6="$CF_V6" ;;
        2)  fetch_arvan_ranges
            RANGES="$ARVAN_V4"; RANGES6="$ARVAN_V6" ;;
        3)  fetch_cloudflare_ranges; fetch_arvan_ranges
            RANGES="$CF_V4 $ARVAN_V4"; RANGES6="$CF_V6 $ARVAN_V6" ;;
        4)  ask RANGES "Paste space-separated IPv4 CIDRs"
            ask_optional RANGES6 "Paste space-separated IPv6 CIDRs" "(blank for none)" ;;
    esac
    [ -n "$RANGES" ] || { err "No IPv4 ranges resolved - aborting."; return 1; }

    local SSH_PORT FW_HTTPS FW_HTTP TUN_PORT FOREIGN_IP=""
    ask_port SSH_PORT "SSH port to keep open" 22
    ask_port FW_HTTPS "HTTPS port to expose to CDN" 443
    ask_port FW_HTTP  "HTTP port to expose to CDN"  80
    ask_port_optional TUN_PORT "Tunnel port (e.g. 8443)"
    if [ -n "$TUN_PORT" ]; then
        ask_optional FOREIGN_IP "Foreign server IP allowed on tunnel port" "(blank = any)"
    fi

    if [ -n "$RANGES6" ] && [ -f /etc/default/ufw ]; then
        sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw 2>/dev/null
    fi

    warn "Resetting firewall and applying rules..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1
    ok "Allowed SSH on ${SSH_PORT}/tcp"

    local cidr
    for cidr in $RANGES; do
        ufw allow from "$cidr" to any port "$FW_HTTPS" proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port "$FW_HTTP"  proto tcp >/dev/null 2>&1
    done
    for cidr in $RANGES6; do
        ufw allow from "$cidr" to any port "$FW_HTTPS" proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port "$FW_HTTP"  proto tcp >/dev/null 2>&1
    done
    ok "Allowed ${FW_HTTPS},${FW_HTTP} only from selected CDN ranges."

    if [ -n "$TUN_PORT" ]; then
        if [ -n "$FOREIGN_IP" ]; then
            ufw allow from "$FOREIGN_IP" to any port "$TUN_PORT" proto tcp >/dev/null 2>&1
            ok "Allowed tunnel ${TUN_PORT} only from ${FOREIGN_IP}"
        else
            ufw allow "${TUN_PORT}/tcp" >/dev/null 2>&1
            warn "Tunnel ${TUN_PORT} open to ANY (no foreign IP set)."
        fi
    fi

    ufw --force enable >/dev/null 2>&1
    ok "Firewall enabled."

    if command -v nginx >/dev/null 2>&1; then
        local RIP
        case "$CDN_CHOICE" in
            1)  ask_optional RIP "Also restore real visitor IPs from Cloudflare in nginx?" "[y/N]"
                is_yes "$RIP" && { write_realip cloudflare; systemctl reload nginx 2>/dev/null && ok "Nginx reloaded." || warn "Could not reload nginx."; } ;;
            2)  ask_optional RIP "Also restore real visitor IPs from ArvanCloud in nginx?" "[y/N]"
                is_yes "$RIP" && { write_realip arvan; systemctl reload nginx 2>/dev/null && ok "Nginx reloaded." || warn "Could not reload nginx."; } ;;
            3)  ask_optional RIP "Also restore real visitor IPs in nginx? (pick the CDN that proxies clients)" "[c=Cloudflare / a=Arvan / blank=skip]"
                case "$RIP" in
                    c|C) write_realip cloudflare; systemctl reload nginx 2>/dev/null && ok "Nginx reloaded." || warn "Could not reload nginx." ;;
                    a|A) write_realip arvan;      systemctl reload nginx 2>/dev/null && ok "Nginx reloaded." || warn "Could not reload nginx." ;;
                esac ;;
        esac
    fi

    if [ "$CDN_CHOICE" = "1" ] || [ "$CDN_CHOICE" = "3" ]; then
        warn "Cloudflare proxy (orange cloud) only forwards standard ports."
        warn "HTTPS must be one of: 443, 2053, 2083, 2087, 2096, 8443."
        warn "Set Cloudflare SSL mode to 'Full' (not Flexible) to avoid redirect loops."
    fi

    echo -e "${INFO}--- Active rules ---${RESET}"
    ufw status numbered
}

firewall_status() {
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose
    else
        warn "ufw not installed."
    fi
}

# ---------------- Reboot persistence ----------------
install_watchdog() {
    cat > /usr/local/bin/goldip-watchdog.sh <<'EOF'
#!/bin/bash
# GoldIP watchdog: revive enabled services if they died.
for svc in nginx x-ui; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service" || continue
    systemctl is-enabled --quiet "$svc" 2>/dev/null || continue
    systemctl is-active  --quiet "$svc" 2>/dev/null || systemctl restart "$svc"
done
EOF
    chmod +x /usr/local/bin/goldip-watchdog.sh

    cat > /etc/systemd/system/goldip-watchdog.service <<'EOF'
[Unit]
Description=GoldIP service watchdog
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/goldip-watchdog.sh
EOF

    cat > /etc/systemd/system/goldip-watchdog.timer <<'EOF'
[Unit]
Description=Run GoldIP watchdog every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now goldip-watchdog.timer >/dev/null 2>&1
    ok "Watchdog installed (checks every 60s; only revives enabled services)."
    warn "To stop it later: systemctl disable --now goldip-watchdog.timer"
}

# enable_persistence [silent]
enable_persistence() {
    local mode="${1:-}"

    if command -v nginx >/dev/null 2>&1; then
        systemctl enable nginx >/dev/null 2>&1 && ok "Nginx enabled on boot." \
            || warn "Could not enable nginx."
        mkdir -p /etc/systemd/system/nginx.service.d
        local after="network-online.target"
        if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
            after="network-online.target x-ui.service"
        fi
        cat > /etc/systemd/system/nginx.service.d/goldip.conf <<EOF
[Unit]
After=${after}
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=3s
EOF
        ok "Nginx ordering + auto-restart drop-in written."
    else
        warn "Nginx not installed; skipping nginx persistence."
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        systemctl enable x-ui >/dev/null 2>&1 && ok "x-ui enabled on boot." \
            || warn "Could not enable x-ui."
        mkdir -p /etc/systemd/system/x-ui.service.d
        cat > /etc/systemd/system/x-ui.service.d/goldip.conf <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=3s
EOF
        ok "x-ui auto-restart drop-in written."
    else
        warn "x-ui.service not found; skipping (run this on the server hosting 3x-ui)."
    fi

    systemctl daemon-reload >/dev/null 2>&1
    ok "systemd reloaded - services will start & self-heal after reboot."

    if [ "$mode" != "silent" ]; then
        if systemctl list-unit-files 2>/dev/null | grep -q '^goldip-watchdog\.timer'; then
            ok "Watchdog already installed and active."
        else
            local WD
            ask_optional WD "Install 1-minute watchdog to auto-revive nginx/x-ui if they crash?" "[y/N]"
            is_yes "$WD" && install_watchdog
        fi
    fi
}

uninstall() {
    local D
    ask D "Domain config to remove" "(e.g. en.goldip.me)"
    rm -f "${NGINX_CONF_DIR}/${D}.conf"
    nginx -t 2>/dev/null && systemctl reload nginx
    ok "Removed config for ${D}"
}

# ---------------- Menu ----------------
menu() {
    while true; do
        clear
        echo -e "${TITLE}"; header; echo -e "${RESET}"
        echo -e "  ${M1}1)  Install / Configure camouflage site${RESET}"
        echo -e "  ${M9}2)  Start Nginx${RESET}"
        echo -e "  ${M3}3)  Stop Nginx${RESET}"
        echo -e "  ${M4}4)  Restart Nginx${RESET}"
        echo -e "  ${M5}5)  Reload Nginx (apply config)${RESET}"
        echo -e "  ${M7}6)  Status / Monitoring${RESET}"
        echo -e "  ${M8}7)  View color-coded logs${RESET}"
        echo -e "  ${M2}8)  Uninstall a domain config${RESET}"
        echo -e "  ${M11}9)  Setup firewall (CDN + tunnel lockdown)${RESET}"
        echo -e "  ${M10}10) Firewall status${RESET}"
        echo -e "  ${M12}11) Fix auto-start after reboot (persistence)${RESET}"
        echo -e "  ${M6}0)  Exit${RESET}"
        local CH
        ask_optional CH "Choose"
        case "$CH" in
            1) do_install ;;
            2) svc start ;;
            3) svc stop ;;
            4) svc restart ;;
            5) svc reload ;;
            6) show_status ;;
            7) view_logs ;;
            8) uninstall ;;
            9) setup_firewall ;;
            10) firewall_status ;;
            11) enable_persistence ;;
            0) exit 0 ;;
            *) err "Invalid choice." ;;
        esac
        local _
        ask_optional _ "Press Enter to continue..."
    done
}

# ---------------- Entry ----------------
require_root
menu
