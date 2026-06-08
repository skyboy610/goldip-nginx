#!/bin/bash
# ============================================================
#  GoldIP Nginx Camouflage Installer & Manager
# ============================================================
#  Installs Nginx in front of a local service (Xray/3x-ui),
#  serves a real camouflage site on "/", and proxies a secret
#  path to the local service. Supports OFFLINE install for
#  Iran servers (place .deb files in ./nginx-offline/).
# ============================================================

set -uo pipefail

# ---------------- Colors ----------------
RESET='\033[0m'
# menu line colors (each unique, never white)
M1='\033[1;36m'   # cyan
M2='\033[1;35m'   # magenta
M3='\033[1;34m'   # blue
M4='\033[1;32m'   # green text
M5='\033[1;33m'   # yellow text
M6='\033[1;31m'   # red text
M7='\033[1;95m'   # bright magenta
M8='\033[1;96m'   # bright cyan
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

# ---------------- Detect inbounds from x-ui DB ----------------
detect_inbounds() {
    local db=""
    for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do
        [ -f "$c" ] && db="$c" && break
    done
    if [ -z "$db" ]; then
        echo -e "${PROMPT}x-ui.db not found. Enter full path (blank to skip):${RESET}"
        read -r db
        [ -n "$db" ] && [ -f "$db" ] || { warn "No database. Falling back to manual entry."; return 0; }
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        warn "sqlite3 not installed; cannot auto-detect. Use manual entry."
        warn "Install with: apt-get install -y sqlite3"
        return 0
    fi

    ok "Reading inbounds from: $db"
    echo -e "${INFO}Detected inbounds (port | network | path) — use these for manual entry below:${RESET}"
    # stream_settings holds JSON: network + (ws|httpupgrade|xhttp)Settings.path
    sqlite3 "$db" "SELECT port, stream_settings FROM inbounds;" 2>/dev/null | while IFS='|' read -r port ss; do
        net=$(echo "$ss" | grep -oE '"network"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        path=$(echo "$ss" | grep -oE '"path"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        [ -z "$net" ] && net="?"
        [ -z "$path" ] && path="(none)"
        echo -e "  ${M8}port ${port}${RESET} | ${M4}${net}${RESET} | ${M5}${path}${RESET}"
    done
    echo -e "${WARN_BG} NOTE ${RESET} Detection is read-only; confirm values and enter them manually next."
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
# Sets global LOCATIONS. Returns 0 on success (>=1 inbound), 1 on failure.
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
        warn "sqlite3 not installed — cannot auto-build."
        warn "Install: apt-get install -y sqlite3   (or place .deb in ./sqlite-offline/)"
        return 1
    fi

    ok "Reading inbounds from: $db"
    LOCATIONS=""
    local added=0 skipped=0
    local SQL_UPDATES=""
    # SQLite expression to turn TLS off in stream_settings (handles spaced/unspaced JSON)
    local TLSOFF="stream_settings=replace(replace(stream_settings,'\"security\": \"tls\"','\"security\": \"none\"'),'\"security\":\"tls\"','\"security\":\"none\"')"
    USED_PORTS=$(ss -ltn 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': ' | tr '\n' ' ')
    TAKEN_PORTS=""
    SEEN_PATHS=""

    while IFS='|' read -r port ss; do
        [ -n "$port" ] || continue
        case "$port" in *[!0-9]*) continue ;; esac
        local net path fport ltype
        net=$(printf '%s' "$ss" | grep -oE '"network"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        path=$(printf '%s' "$ss" | grep -oE '"path"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        # Nginx location matches the URI path only — strip any query string (?ed=...)
        path=${path%%\?*}

        case "$net" in
            ws|httpupgrade) ltype="upgrade" ;;
            xhttp|splithttp) ltype="xhttp" ;;
            *)
                warn "Skip port ${port}: transport '${net:-unknown}' not proxied via Nginx (tcp/reality/grpc handle TLS themselves)."
                skipped=$((skipped+1)); continue ;;
        esac

        if [ -z "$path" ]; then
            warn "Skip port ${port} (${net}): no path set."
            skipped=$((skipped+1)); continue
        fi

        # Path "/" conflicts with the camouflage site — cannot coexist
        if [ "$path" = "/" ]; then
            warn "Skip port ${port}: path is '/' which collides with the camouflage site."
            warn "  -> set a unique path for this inbound in x-ui (e.g. /sub${port})."
            skipped=$((skipped+1)); continue
        fi

        # Skip duplicate paths (Nginx forbids two identical locations)
        case " $SEEN_PATHS " in
            *" $path "*)
                warn "Skip port ${port}: path '${path}' already used by another inbound."
                skipped=$((skipped+1)); continue ;;
        esac
        SEEN_PATHS="${SEEN_PATHS} ${path}"

        # Notice if TLS currently on (will be disabled — Nginx terminates TLS)
        if printf '%s' "$ss" | grep -qE '"security"[ ]*:[ ]*"tls"'; then
            warn "Inbound ${port}: TLS is ON -> will be set to none (Nginx terminates TLS)."
        fi

        # Resolve conflict with Nginx listen ports
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
        ok "Added ${net} -> ${path} (127.0.0.1:${fport})"
        added=$((added+1))
    done < <(sqlite3 -separator '|' "$db" "SELECT port, replace(replace(stream_settings, char(10), ' '), char(13), ' ') FROM inbounds;" 2>/dev/null)

    echo -e "${INFO}Auto-build done: ${added} added, ${skipped} skipped.${RESET}"
    [ "$added" -ge 1 ] || return 1

    # Apply listen=127.0.0.1 to the database
    if [ -n "$SQL_UPDATES" ]; then
        echo -e "${WARN_BG} ACTION ${RESET} Set these inbounds to listen on 127.0.0.1 in the x-ui DB now?"
        warn "A backup is made first, then x-ui restarts. Tunnel inbounds will only"
        warn "work AFTER you point the foreign server to the Arvan domain (port ${HTTPS_PORT})."
        echo -e "${PROMPT}Apply now? [y/N]:${RESET}"
        read -r AP
        if [ "$AP" = "y" ] || [ "$AP" = "Y" ]; then
            local bak="${db}.bak.$(date +%s)"
            cp "$db" "$bak" && ok "DB backed up: $bak" || { err "Backup failed — aborting DB change."; return 0; }
            if printf '%s' "$SQL_UPDATES" | sqlite3 "$db" 2>/tmp/sql_err.log; then
                ok "Database updated (listen=127.0.0.1)."
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
            warn "Skipped DB change. You must set listen=127.0.0.1 manually in the panel,"
            warn "otherwise inbounds stay public and bypass Nginx."
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
        [ "$DISC" = "1" ] && warn "Auto-build unavailable — switching to manual entry."
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
    echo -e "${INFO}--- nginx -t ---${RESET}"
    nginx -t 2>&1
    echo -e "${INFO}--- listening sockets ---${RESET}"
    ss -ltnp 2>/dev/null | grep nginx || warn "No nginx sockets found."
}

# ---------------- Color-coded logs ----------------
view_logs() {
    echo -e "${PROMPT}Domain to view logs for (blank = global error log):${RESET}"
    read -r LOGDOM
    local acc err_log
    if [ -n "$LOGDOM" ]; then
        acc="/var/log/nginx/${LOGDOM}.access.log"
        err_log="/var/log/nginx/${LOGDOM}.error.log"
    else
        acc="/var/log/nginx/access.log"
        err_log="/var/log/nginx/error.log"
    fi

    echo -e "${INFO}===== ERROR LOG (last 30) =====${RESET}"
    if [ -f "$err_log" ]; then
        tail -n 30 "$err_log" | while IFS= read -r line; do
            if echo "$line" | grep -qiE '\[(error|crit|alert|emerg)\]'; then
                echo -e "${ERR_BG} ERR  ${RESET} $line"
            elif echo "$line" | grep -qiE '\[warn\]'; then
                echo -e "${WARN_BG} WARN ${RESET} $line"
            else
                echo -e "${OK_BG} INFO ${RESET} $line"
            fi
        done
    else
        warn "No error log at $err_log"
    fi

    echo -e "${INFO}===== ACCESS LOG (last 30) =====${RESET}"
    if [ -f "$acc" ]; then
        tail -n 30 "$acc" | while IFS= read -r line; do
            code=$(echo "$line" | grep -oE '" [1-5][0-9][0-9] ' | tr -d '" ')
            case "$code" in
                5*) echo -e "${ERR_BG} ${code} ${RESET} $line" ;;
                4*) echo -e "${WARN_BG} ${code} ${RESET} $line" ;;
                2*|3*) echo -e "${OK_BG} ${code} ${RESET} $line" ;;
                *) echo -e "$line" ;;
            esac
        done
    else
        warn "No access log at $acc"
    fi
}

# ---------------- Firewall ----------------
# Default ArvanCloud CDN edge ranges (verify against panel; update if changed).
ARVAN_RANGES_DEFAULT="185.143.232.0/22 188.229.116.0/22 94.182.182.0/24 2.144.0.0/12 92.114.16.0/20 195.181.169.0/24"

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

    echo -e "${PROMPT}SSH port to keep open [22]:${RESET}"
    read -r SSH_PORT; SSH_PORT=${SSH_PORT:-22}

    echo -e "${PROMPT}HTTPS port to expose to CDN [443]:${RESET}"
    read -r FW_HTTPS; FW_HTTPS=${FW_HTTPS:-443}

    echo -e "${PROMPT}HTTP port to expose to CDN [80]:${RESET}"
    read -r FW_HTTP; FW_HTTP=${FW_HTTP:-80}

    echo -e "${INFO}ArvanCloud CDN ranges to allow on web ports.${RESET}"
    echo -e "${PROMPT}Press Enter to use defaults, or paste space-separated CIDRs:${RESET}"
    echo -e "${INFO}default: ${ARVAN_RANGES_DEFAULT}${RESET}"
    read -r RANGES
    [ -n "$RANGES" ] || RANGES="$ARVAN_RANGES_DEFAULT"

    echo -e "${PROMPT}Tunnel port (e.g. 8443) — blank to skip:${RESET}"
    read -r TUN_PORT
    if [ -n "$TUN_PORT" ]; then
        echo -e "${PROMPT}Foreign server IP allowed on tunnel port (blank = any):${RESET}"
        read -r FOREIGN_IP
    fi

    warn "Resetting firewall and applying rules..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # SSH first — never lock yourself out
    ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1
    ok "Allowed SSH on ${SSH_PORT}/tcp"

    # Web ports only from CDN ranges
    for cidr in $RANGES; do
        ufw allow from "$cidr" to any port "$FW_HTTPS" proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port "$FW_HTTP"  proto tcp >/dev/null 2>&1
    done
    ok "Allowed ${FW_HTTPS},${FW_HTTP} only from CDN ranges"

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
        echo -e "  ${M1}1)${RESET} ${M1}Install / Configure camouflage site${RESET}"
        echo -e "  ${M2}2)${RESET} ${M2}Start Nginx${RESET}"
        echo -e "  ${M3}3)${RESET} ${M3}Stop Nginx${RESET}"
        echo -e "  ${M4}4)${RESET} ${M4}Restart Nginx${RESET}"
        echo -e "  ${M5}5)${RESET} ${M5}Reload Nginx (apply config)${RESET}"
        echo -e "  ${M7}6)${RESET} ${M7}Status / Monitoring${RESET}"
        echo -e "  ${M8}7)${RESET} ${M8}View color-coded logs${RESET}"
        echo -e "  ${M6}8)${RESET} ${M6}Uninstall a domain config${RESET}"
        echo -e "  ${M4}9)${RESET} ${M4}Setup firewall (CDN + tunnel lockdown)${RESET}"
        echo -e "  ${M1}10)${RESET} ${M1}Firewall status${RESET}"
        echo -e "  ${M6}0)${RESET} ${M6}Exit${RESET}"
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
            0) exit 0 ;;
            *) err "Invalid choice." ;;
        esac
        echo -e "${PROMPT}Press Enter to continue...${RESET}"; read -r _
    done
}

# ---------------- Entry ----------------
require_root
menu
