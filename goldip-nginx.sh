#!/bin/bash
# ============================================================
#  GoldIP Nginx Camouflage Installer & Manager
# ============================================================
#  Installs Nginx in front of a local service (Xray/3x-ui),
#  serves a real camouflage site on "/", and proxies a secret
#  path to the local service. Supports OFFLINE install for
#  Iran servers (place .deb files in ./nginx-offline/).
#
#  Fixes in this build:
#   - Cloudflare CDN IP ranges added to firewall (v4 + v6)
#   - Reboot persistence: nginx + x-ui auto-start & self-heal
#   - Color-coded log viewer rewritten (auto-discovers logs)
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
PROMPT='\033[1;35m'
INFO='\033[1;34m'

# message badges: colored background + white text
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
# ArvanCloud CDN edge ranges (verify against panel; update if changed).
ARVAN_RANGES_DEFAULT="185.143.232.0/22 188.229.116.0/22 94.182.182.0/24 2.144.0.0/12 92.114.16.0/20 195.181.169.0/24"

CF_V4=""
CF_V6=""

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

# ---------------- Fully automatic: build locations from x-ui DB ----------------
# Lists all inbounds numbered, lets user pick which go behind Nginx.
# Selected -> listen 127.0.0.1, TLS off, location built. Unselected -> untouched.
# Sets global LOCATIONS. Returns 0 on success (>=1 selected & built), 1 otherwise.
auto_build_locations() {
    local db=""
    for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do
        [ -f "$c" ] && db="$c" && break
    done
    if [ -z "$db" ]; then
        echo -e "${PROMPT}x-ui.db not found. Enter full path (blank to cancel):${RESET}"
        read -r db
        { [ -n "$db" ] && [ -f "$db" ]; } || { warn "No database found."; return 1; }
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        warn "sqlite3 not installed - cannot auto-build."
        warn "Install: apt-get install -y sqlite3   (or place .deb in ./sqlite-offline/)"
        return 1
    fi

    ok "Reading inbounds from: $db"

    # Read all inbounds into parallel arrays
    local -a IN_PORT IN_NET IN_PATH
    local idx=0 port ss net rawpath path
    while IFS='|' read -r port ss; do
        [ -n "$port" ] || continue
        case "$port" in *[!0-9]*) continue ;; esac
        net=$(printf '%s' "$ss" | grep -oE '"network"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        rawpath=$(printf '%s' "$ss" | grep -oE '"path"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        path=${rawpath%%\?*}   # strip query string for Nginx location
        idx=$((idx+1))
        IN_PORT[$idx]="$port"
        IN_NET[$idx]="${net:-unknown}"
        IN_PATH[$idx]="$path"
    done < <(sqlite3 -separator '|' "$db" "SELECT port, replace(replace(stream_settings, char(10), ' '), char(13), ' ') FROM inbounds;" 2>/dev/null)

    [ "$idx" -ge 1 ] || { warn "No inbounds found in database."; return 1; }

    # Numbered list
    echo -e "${INFO}Inbounds found:${RESET}"
    local n
    for n in $(seq 1 "$idx"); do
        echo -e "  ${M8}${n})${RESET} ${M4}port ${IN_PORT[$n]}${RESET} | ${M5}${IN_NET[$n]}${RESET} | ${M1}${IN_PATH[$n]:-(no path)}${RESET}"
    done
    echo -e "${PROMPT}Which inbounds go BEHIND Nginx? (comma-separated, e.g. 1,3,4)${RESET}"
    echo -e "${INFO}Leave tunnel inbounds OUT - they stay direct on 0.0.0.0 and are not touched.${RESET}"
    read -r SEL
    [ -n "$SEL" ] || { warn "Nothing selected."; return 1; }

    LOCATIONS=""
    local added=0 skipped=0
    local SQL_UPDATES=""
    local TLSOFF="stream_settings=replace(replace(stream_settings,'\"security\": \"tls\"','\"security\": \"none\"'),'\"security\":\"tls\"','\"security\":\"none\"')"
    USED_PORTS=$(ss -ltn 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': ' | tr '\n' ' ')
    TAKEN_PORTS=""
    SEEN_PATHS=""

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

        fport="$port"
        if [ "$port" = "$HTTPS_PORT" ] || [ "$port" = "$HTTP_PORT" ]; then
            fport=$(free_port) || { err "No free local port available."; return 1; }
            SQL_UPDATES="${SQL_UPDATES}UPDATE inbounds SET listen='127.0.0.1', port=${fport}, ${TLSOFF} WHERE port=${port};
"
            warn "Port ${port} conflicts with Nginx -> moved inbound to 127.0.0.1:${fport}"
        else
            SQL_UPDATES="${SQL_UPDATES}UPDATE inbounds SET listen='127.0.0.1', ${TLSOFF} WHERE port=${port};
"
        fi
        TAKEN_PORTS="${TAKEN_PORTS} ${fport}"

        LOCATIONS="${LOCATIONS}
$(make_location "$ltype" "$path" "$fport")"
        ok "Added #${sel} ${net} -> ${path} (127.0.0.1:${fport})"
        added=$((added+1))
    done

    echo -e "${INFO}Selected: ${added} added, ${skipped} skipped. Unselected inbounds untouched.${RESET}"
    [ "$added" -ge 1 ] || return 1

    # Apply listen=127.0.0.1 + TLS off to the database for selected inbounds
    if [ -n "$SQL_UPDATES" ]; then
        echo -e "${WARN_BG} ACTION ${RESET} Apply listen=127.0.0.1 (and TLS off) to the SELECTED inbounds now?"
        warn "A backup is made first, then x-ui restarts. Unselected (tunnel) inbounds are NOT changed."
        echo -e "${PROMPT}Apply now? [y/N]:${RESET}"
        read -r AP
        if [ "$AP" = "y" ] || [ "$AP" = "Y" ]; then
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
    echo -e "${PROMPT}Domain (e.g. en.goldip.me):${RESET}"
    read -r DOMAIN
    [ -n "$DOMAIN" ] || { err "Domain required."; exit 1; }
    # allow multiple domains: accept comma or space, normalize to spaces
    DOMAIN=$(printf '%s' "$DOMAIN" | tr ',' ' ' | tr -s ' ' | sed -E 's/^ +| +$//g')
    PRIMARY=$(printf '%s' "$DOMAIN" | awk '{print $1}')

    echo -e "${PROMPT}HTTPS listen port [443]:${RESET}"
    read -r HTTPS_PORT; HTTPS_PORT=${HTTPS_PORT:-443}

    echo -e "${PROMPT}HTTP listen port [80]:${RESET}"
    read -r HTTP_PORT; HTTP_PORT=${HTTP_PORT:-80}

    echo -e "${PROMPT}Full path to SSL certificate (cert.pem):${RESET}"
    read -r SSL_CERT
    [ -f "$SSL_CERT" ] || { err "Cert not found: $SSL_CERT"; exit 1; }

    echo -e "${PROMPT}Full path to SSL private key (key.pem):${RESET}"
    read -r SSL_KEY
    [ -f "$SSL_KEY" ] || { err "Key not found: $SSL_KEY"; exit 1; }

    # Behind Cloudflare? restore real client IP
    echo -e "${PROMPT}Is this server behind Cloudflare CDN? (restore real visitor IP) [y/N]:${RESET}"
    read -r BEHIND_CF

    # ---- Inbounds ----
    LOCATIONS=""
    echo -e "${INFO}Inbound configuration:${RESET}"
    echo -e "  ${M1}1)${RESET} ${M4}Fully automatic (read & configure from x-ui database)${RESET}"
    echo -e "  ${M2}2)${RESET} ${M5}Manual entry${RESET}"
    echo -e "${PROMPT}Selection [1/2]:${RESET}"
    read -r DISC

    if [ "$DISC" = "1" ] && auto_build_locations; then
        ok "Locations built automatically from database."
    else
        [ "$DISC" = "1" ] && warn "Auto-build unavailable - switching to manual entry."
        echo -e "${PROMPT}How many inbounds to add to Nginx?${RESET}"
        read -r NIN
        case "$NIN" in ''|*[!0-9]*) err "Must be a number."; exit 1 ;; esac

        local i=1
        while [ "$i" -le "$NIN" ]; do
            echo -e "${INFO}--- Inbound #${i} ---${RESET}"
            echo -e "${PROMPT}Path (e.g. /ws${i}):${RESET}"
            read -r P_PATH
            [ -n "$P_PATH" ] || { err "Path required."; exit 1; }
            [ "${P_PATH:0:1}" = "/" ] || P_PATH="/$P_PATH"

            echo -e "${PROMPT}Local Xray port (127.0.0.1:PORT):${RESET}"
            read -r P_PORT
            case "$P_PORT" in ''|*[!0-9]*) err "Port must be a number."; exit 1 ;; esac

            echo -e "${INFO}Transport type:${RESET}"
            echo -e "  ${M1}1)${RESET} ${M4}WebSocket (ws)${RESET}"
            echo -e "  ${M2}2)${RESET} ${M5}HTTPUpgrade${RESET}"
            echo -e "  ${M3}3)${RESET} ${M7}XHTTP (splithttp)${RESET}"
            echo -e "${PROMPT}Selection [1/2/3]:${RESET}"
            read -r P_TYPE

            case "$P_TYPE" in
                1|2) LOCATIONS="${LOCATIONS}
$(make_location upgrade "$P_PATH" "$P_PORT")" ;;
                3)   LOCATIONS="${LOCATIONS}
$(make_location xhttp "$P_PATH" "$P_PORT")" ;;
                *)   err "Invalid transport type."; exit 1 ;;
            esac
            i=$((i + 1))
        done
    fi

    echo -e "${INFO}Camouflage site type:${RESET}"
    echo -e "  ${M1}1)${RESET} ${M4}Reverse-proxy to an existing website${RESET}"
    echo -e "  ${M2}2)${RESET} ${M5}Serve a local HTML file${RESET}"
    echo -e "${PROMPT}Selection [1/2]:${RESET}"
    read -r CAMO

    if [ "$CAMO" = "1" ]; then
        echo -e "${PROMPT}Website URL to proxy (e.g. https://example.com):${RESET}"
        read -r PROXY_URL
        [ -n "$PROXY_URL" ] || { err "URL required."; exit 1; }
        PROXY_HOST=$(echo "$PROXY_URL" | sed -E 's#^https?://##; s#/.*##')
        CAMO_BLOCK="location / {
        proxy_pass ${PROXY_URL};
        proxy_set_header Host ${PROXY_HOST};
        proxy_ssl_server_name on;
    }"
    elif [ "$CAMO" = "2" ]; then
        echo -e "${PROMPT}Full path to your index.html:${RESET}"
        read -r HTML_FILE
        [ -f "$HTML_FILE" ] || { err "HTML file not found: $HTML_FILE"; exit 1; }
        mkdir -p "$CAMO_ROOT"
        cp "$HTML_FILE" "$CAMO_ROOT/index.html"
        CAMO_BLOCK="location / {
        root ${CAMO_ROOT};
        index index.html;
    }"
    else
        err "Invalid selection."; exit 1
    fi
}

# ---------------- Write config ----------------
write_config() {
    mkdir -p "$NGINX_CONF_DIR"
    # remove default site to avoid port conflicts
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null

    # Optional: restore real visitor IP when behind Cloudflare
    if [ "${BEHIND_CF:-}" = "y" ] || [ "${BEHIND_CF:-}" = "Y" ]; then
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
        exit 1
    fi
}

do_install() {
    install_nginx
    gather_inputs
    write_config
    # Make everything survive reboots automatically (no watchdog prompt here)
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
# Colorizes one nginx ERROR-log line.
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

# Colorizes one nginx ACCESS-log line by HTTP status code.
colorize_access_line() {
    local line="$1" code
    # status = first 3-digit number right after the quoted request: ..."GET / HTTP/1.1" 200 ...
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
    # Discover available nginx logs so the user always picks a populated one.
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
    echo -e "${PROMPT}Pick a log number to view (or 'f' to live-follow it):${RESET}"
    read -r PICK

    local follow=0
    case "$PICK" in
        f|F) follow=1
             echo -e "${PROMPT}Which number to follow?${RESET}"
             read -r PICK ;;
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

write_cf_realip() {
    [ -n "$CF_V4" ] || fetch_cloudflare_ranges
    local f="${NGINX_CONF_DIR}/00-cloudflare-realip.conf"
    {
        echo "# Restore real client IP from Cloudflare (auto-generated by GoldIP)"
        for c in $CF_V4; do echo "set_real_ip_from $c;"; done
        for c in $CF_V6; do echo "set_real_ip_from $c;"; done
        echo "real_ip_header CF-Connecting-IP;"
        echo "real_ip_recursive on;"
    } > "$f"
    if nginx -t 2>/tmp/nginx_test.log; then
        ok "Cloudflare real-IP restore enabled ($f)."
    else
        warn "real-IP config rejected by nginx - removing it."
        rm -f "$f"
        cat /tmp/nginx_test.log
    fi
}

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
    echo -e "${PROMPT}Selection [1/2/3/4]:${RESET}"
    read -r CDN_CHOICE

    local RANGES="" RANGES6=""
    case "$CDN_CHOICE" in
        1)  fetch_cloudflare_ranges
            RANGES="$CF_V4"; RANGES6="$CF_V6" ;;
        2)  RANGES="$ARVAN_RANGES_DEFAULT" ;;
        3)  fetch_cloudflare_ranges
            RANGES="$CF_V4 $ARVAN_RANGES_DEFAULT"; RANGES6="$CF_V6" ;;
        4)  echo -e "${PROMPT}Paste space-separated IPv4 CIDRs:${RESET}"
            read -r RANGES
            echo -e "${PROMPT}Paste space-separated IPv6 CIDRs (blank for none):${RESET}"
            read -r RANGES6 ;;
        *)  warn "No valid CDN choice - defaulting to Cloudflare."
            fetch_cloudflare_ranges
            RANGES="$CF_V4"; RANGES6="$CF_V6" ;;
    esac
    [ -n "$RANGES" ] || { err "No IPv4 ranges resolved - aborting."; return 1; }

    echo -e "${PROMPT}SSH port to keep open [22]:${RESET}"
    read -r SSH_PORT; SSH_PORT=${SSH_PORT:-22}

    echo -e "${PROMPT}HTTPS port to expose to CDN [443]:${RESET}"
    read -r FW_HTTPS; FW_HTTPS=${FW_HTTPS:-443}

    echo -e "${PROMPT}HTTP port to expose to CDN [80]:${RESET}"
    read -r FW_HTTP; FW_HTTP=${FW_HTTP:-80}

    echo -e "${PROMPT}Tunnel port (e.g. 8443) - blank to skip:${RESET}"
    read -r TUN_PORT
    if [ -n "$TUN_PORT" ]; then
        echo -e "${PROMPT}Foreign server IP allowed on tunnel port (blank = any):${RESET}"
        read -r FOREIGN_IP
    fi

    # Ensure ufw handles IPv6 if we have v6 ranges
    if [ -n "$RANGES6" ] && [ -f /etc/default/ufw ]; then
        sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw 2>/dev/null
    fi

    warn "Resetting firewall and applying rules..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # SSH first - never lock yourself out
    ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1
    ok "Allowed SSH on ${SSH_PORT}/tcp"

    # Web ports only from CDN ranges (IPv4)
    local cidr
    for cidr in $RANGES; do
        ufw allow from "$cidr" to any port "$FW_HTTPS" proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port "$FW_HTTP"  proto tcp >/dev/null 2>&1
    done
    # Web ports from CDN ranges (IPv6)
    for cidr in $RANGES6; do
        ufw allow from "$cidr" to any port "$FW_HTTPS" proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port "$FW_HTTP"  proto tcp >/dev/null 2>&1
    done
    ok "Allowed ${FW_HTTPS},${FW_HTTP} only from selected CDN ranges."

    # Tunnel port
    if [ -n "$TUN_PORT" ]; then
        if [ -n "${FOREIGN_IP:-}" ]; then
            ufw allow from "$FOREIGN_IP" to any port "$TUN_PORT" proto tcp >/dev/null 2>&1
            ok "Allowed tunnel ${TUN_PORT} only from ${FOREIGN_IP}"
        else
            ufw allow "${TUN_PORT}/tcp" >/dev/null 2>&1
            warn "Tunnel ${TUN_PORT} open to ANY (no foreign IP set)."
        fi
    fi

    ufw --force enable >/dev/null 2>&1
    ok "Firewall enabled."

    # Offer Cloudflare real-IP restore when CF is in the mix
    if [ "$CDN_CHOICE" = "1" ] || [ "$CDN_CHOICE" = "3" ]; then
        if command -v nginx >/dev/null 2>&1; then
            echo -e "${PROMPT}Also restore real visitor IPs from Cloudflare in nginx? [y/N]:${RESET}"
            read -r RIP
            if [ "$RIP" = "y" ] || [ "$RIP" = "Y" ]; then
                write_cf_realip
                systemctl reload nginx 2>/dev/null && ok "Nginx reloaded with real-IP." \
                    || warn "Could not reload nginx."
            fi
        fi
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

    # ---- Nginx ----
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

    # ---- x-ui (3x-ui) ----
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
            echo -e "${PROMPT}Install 1-minute watchdog to auto-revive nginx/x-ui if they crash? [y/N]:${RESET}"
            read -r WD
            { [ "$WD" = "y" ] || [ "$WD" = "Y" ]; } && install_watchdog
        fi
    fi
}

uninstall() {
    echo -e "${PROMPT}Domain config to remove (e.g. en.goldip.me):${RESET}"
    read -r D
    [ -n "$D" ] || { err "Domain required."; return; }
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
        echo -e "${PROMPT}Choose:${RESET}"
        read -r CH
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
        echo -e "${PROMPT}Press Enter to continue...${RESET}"; read -r _
    done
}

# ---------------- Entry ----------------
require_root
menu
