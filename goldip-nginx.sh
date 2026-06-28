#!/bin/bash
# ============================================================
#  GoldIP Nginx Camouflage Installer & Manager  v3.0
#  Compatible with 3x-ui >= 3.4.1 (hosts table, no externalProxy)
# ============================================================
set -uo pipefail

RESET='\033[0m'

# ── Message badge colours (green/red reserved for ok/err) ─────────────────
OK_BG='\033[42m\033[97m'
WARN_BG='\033[43m\033[97m'
ERR_BG='\033[41m\033[97m'

ok()   { echo -e "${OK_BG} OK ${RESET} \033[1;32m$1\033[0m"; }
warn() { echo -e "${WARN_BG} WARN ${RESET} \033[1;33m$1\033[0m"; }
err()  { echo -e "${ERR_BG} ERROR ${RESET} \033[1;31m$1\033[0m"; }

# ── Prompt/label colours ──────────────────────────────────────────────────
PROMPT='\033[1;96m'
HINT='\033[1;97m'
INFO='\033[1;34m'
TITLE='\033[1;36m'

# ── Menu item colours  (NO green/red) ────────────────────────────────────
# Each colour is used on exactly ONE line in the menu
C_ITEM_1='\033[1;36m'    # Cyan          – line 1
C_ITEM_2='\033[1;35m'    # Magenta        – line 2
C_ITEM_3='\033[1;34m'    # Blue           – line 3
C_ITEM_4='\033[1;33m'    # Yellow         – line 4
C_ITEM_5='\033[1;95m'    # Bright Magenta – line 5
C_ITEM_6='\033[1;96m'    # Bright Cyan    – line 6
C_ITEM_7='\033[1;94m'    # Bright Blue    – line 7
C_ITEM_8='\033[1;91m'    # RED            – line 8 (Remove domain - allowed)
C_ITEM_9='\033[1;93m'    # Bright Yellow  – line 9
C_ITEM_10='\033[1;97m'   # White          – line 10
C_ITEM_11='\033[38;5;214m'  # Orange      – line 11
C_ITEM_12='\033[1;91m'   # RED            – line 12 (Full uninstall - allowed)
C_ITEM_0='\033[38;5;245m'   # Grey        – line 0 (Exit)

NGINX_CONF_DIR="/etc/nginx/conf.d"
CAMO_ROOT="/var/www/goldip"
GOLDIP_DOMAIN="goldip.net"

CF_V4_DEFAULT="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF_V6_DEFAULT="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
ARVAN_V4_DEFAULT="178.131.120.48/28 185.143.232.0/22 185.215.232.0/22 188.229.116.16/30 2.144.3.128/28 37.32.16.0/27 37.32.17.0/27 37.32.18.0/27 37.32.19.0/27 78.157.36.112/28 94.101.182.0/27 94.101.183.0/28"
ARVAN_V6_DEFAULT=""
CF_V4=""; CF_V6=""; ARVAN_V4=""; ARVAN_V6=""

# ── Input helpers ──────────────────────────────────────────────────────────
ask() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans
    while true; do
        [ -n "$__hint" ] && echo -e "${PROMPT}${__q} ${HINT}${__hint}${PROMPT}:${RESET}" \
                         || echo -e "${PROMPT}${__q}:${RESET}"
        read -r __ans
        [ -n "$__ans" ] && { printf -v "$__var" '%s' "$__ans"; return 0; }
        warn "This field can't be empty. Please try again."
    done
}
ask_optional() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans
    [ -n "$__hint" ] && echo -e "${PROMPT}${__q} ${HINT}${__hint}${PROMPT}:${RESET}" \
                     || echo -e "${PROMPT}${__q}:${RESET}"
    read -r __ans; printf -v "$__var" '%s' "$__ans"
}
ask_number() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans
    while true; do
        [ -n "$__hint" ] && echo -e "${PROMPT}${__q} ${HINT}${__hint}${PROMPT}:${RESET}" \
                         || echo -e "${PROMPT}${__q}:${RESET}"
        read -r __ans
        case "$__ans" in ''|*[!0-9]*) warn "Must be a number."; continue ;; esac
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}
ask_port() {
    local __var="$1" __q="$2" __def="$3" __ans
    while true; do
        echo -e "${PROMPT}${__q} ${HINT}[${__def}]${PROMPT}:${RESET}"; read -r __ans
        [ -n "$__ans" ] || __ans="$__def"
        case "$__ans" in ''|*[!0-9]*) warn "Port must be a number."; continue ;; esac
        { [ "$__ans" -ge 1 ] && [ "$__ans" -le 65535 ]; } || { warn "Port out of range."; continue; }
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}
ask_port_optional() {
    local __var="$1" __q="$2" __ans
    while true; do
        echo -e "${PROMPT}${__q} ${HINT}(blank to skip)${PROMPT}:${RESET}"; read -r __ans
        [ -z "$__ans" ] && { printf -v "$__var" '%s' ""; return 0; }
        case "$__ans" in *[!0-9]*) warn "Port must be a number."; continue ;; esac
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}
ask_file() {
    local __var="$1" __q="$2" __ans
    while true; do
        echo -e "${PROMPT}${__q}:${RESET}"; read -r __ans
        [ -z "$__ans" ] && { warn "Path can't be empty."; continue; }
        [ -f "$__ans" ] || { err "File not found: $__ans"; continue; }
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}
ask_choice() {
    local __var="$1" __q="$2" __valid="$3" __ans
    while true; do
        echo -e "${PROMPT}${__q} ${HINT}[${__valid//|//}]${PROMPT}:${RESET}"; read -r __ans
        printf '%s' "$__ans" | grep -qiE "^(${__valid})$" && { printf -v "$__var" '%s' "$__ans"; return 0; }
        warn "Invalid choice. Allowed: ${__valid//|/, }"
    done
}
is_yes()    { case "$1" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac; }
is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

normalize_url() {
    local u="$1"
    case "$u" in
        http://*|https://*) printf '%s' "$u" ;;
        *) printf 'https://%s' "$u" ;;
    esac
}

# ── Header ────────────────────────────────────────────────────────────────
header() {
cat <<'EOF'
==========================================================
   ____       _     _ ___ ____
  / ___| ___ | | __| |_ _|  _ \
 | |  _ / _ \| |/ _` || || |_) |
 | |_| | (_) | | (_| || ||  __/
  \____|\___/|_|\__,_|___|_|
    N G I N X   C A M O U F L A G E   v3.0
    Compatible with 3x-ui >= 3.4.1 (Hosts API)
==========================================================
EOF
}

require_root() {
    [ "$(id -u)" -eq 0 ] || { err "Run this script as root."; exit 1; }
}

# ── Locate x-ui database ──────────────────────────────────────────────────
find_xui_db() {
    local c
    for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# ── Ensure sqlite3 ───────────────────────────────────────────────────────
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

# ── Install Nginx ─────────────────────────────────────────────────────────
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

# ── Browser-realistic location block ─────────────────────────────────────
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

# ── Find a free local port ────────────────────────────────────────────────
free_port() {
    local p
    for p in $(seq 20000 29999); do
        case " $USED_PORTS " in *" $p "*) continue ;; esac
        case " $TAKEN_PORTS " in *" $p "*) continue ;; esac
        echo "$p"; return 0
    done; return 1
}

# ── Determine ALPN for a given network type ───────────────────────────────
#    ws / httpupgrade  -> ["http/1.1"]
#    xhttp / splithttp -> ["http/1.1","h2"]
#    grpc              -> ["h2"]
#    fallback          -> ["http/1.1"]
alpn_for_net() {
    local net="$1"
    case "$net" in
        grpc)              printf '["h2"]' ;;
        xhttp|splithttp)   printf '["http/1.1","h2"]' ;;
        *)                 printf '["http/1.1"]' ;;
    esac
}

# ── Insert a host row via Python (uses sqlite3 module, no CLI needed) ─────
#
#   Usage: insert_host_py DB INB_ID REMARK ADDRESS PORT SNI ALPN_JSON
#
#   All seven arguments are positional.
#   Returns 0 on success, non-zero on failure.
insert_host_py() {
    python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PYEOF'
import sqlite3, sys, time

db_path   = sys.argv[1]
inbound_id= int(sys.argv[2])
remark    = sys.argv[3]
address   = sys.argv[4]
port      = int(sys.argv[5])
sni       = sys.argv[6]
alpn_json = sys.argv[7]  # e.g. '["http/1.1"]'
now_ms    = int(time.time() * 1000)

try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("""
        INSERT INTO hosts (
            inbound_id, sort_order, remark, server_description,
            is_disabled, is_hidden, tags, address, port,
            security, sni, host_header, path, alpn,
            fingerprint, override_sni_from_address, keep_sni_blank,
            pinned_peer_cert_sha256, verify_peer_cert_by_name,
            allow_insecure, ech_config_list, mux_params, sockopt_params,
            final_mask, vless_route, exclude_from_sub_types,
            mihomo_ip_version, mihomo_x25519, shuffle_host, node_guids,
            created_at, updated_at
        ) VALUES (
            ?, 0, ?, '',
            0, 0, NULL, ?, ?,
            'tls', ?, '', '', ?,
            'chrome', 1, 0,
            NULL, '',
            0, '', '', '',
            '', '', NULL,
            '', 0, 0, NULL,
            ?, ?
        )
    """, (
        inbound_id, remark, address, port,
        sni, alpn_json,
        now_ms, now_ms
    ))
    con.commit()
    con.close()
    print(f"OK host inserted for inbound_id={inbound_id} remark={remark} address={address}:{port}")
    sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ── Strip TLS from stream_settings in the DB (security -> none) ──────────
strip_tls_py() {
    python3 - "$1" "$2" <<'PYEOF'
import sqlite3, json, sys

db_path   = sys.argv[1]
inbound_id= int(sys.argv[2])

try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("SELECT stream_settings FROM inbounds WHERE id=?", (inbound_id,))
    row = cur.fetchone()
    if not row or not row[0]:
        con.close(); sys.exit(0)
    ss = json.loads(row[0])
    ss["security"] = "none"
    for k in ("tlsSettings", "realitySettings", "externalProxy", "externalProxySettings"):
        ss.pop(k, None)
    new_json = json.dumps(ss, separators=(",", ":"), ensure_ascii=False)
    cur.execute("UPDATE inbounds SET stream_settings=? WHERE id=?", (new_json, inbound_id))
    con.commit()
    con.close()
    print(f"OK stream_settings updated for inbound_id={inbound_id}")
    sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ── Auto-build locations AND create hosts in DB ────────────────────────────
auto_build_locations() {
    local db=""
    db=$(find_xui_db)
    if [ -z "$db" ]; then
        ask_optional db "x-ui.db not found. Enter full path" "(blank to cancel)"
        { [ -n "$db" ] && [ -f "$db" ]; } || { warn "No database found."; return 1; }
    fi
    ensure_sqlite3 || return 1
    ok "Reading inbounds from: $db"

    # ── Check python3 ────────────────────────────────────────────────────
    local HAVE_PY=0
    command -v python3 >/dev/null 2>&1 && HAVE_PY=1
    [ "$HAVE_PY" = "1" ] || { err "python3 is required for host creation. Please install it."; return 1; }

    # ── Read all inbounds ─────────────────────────────────────────────────
    local -a IN_ID IN_PORT IN_NET IN_PATH IN_SS
    local idx=0 id port ss net rawpath path
    while IFS='|' read -r id port ss; do
        [ -n "$port" ] || continue
        case "$id"   in ''|*[!0-9]*) continue ;; esac
        case "$port" in    *[!0-9]*) continue ;; esac
        net=$(printf '%s' "$ss" | grep -oE '"network"[ ]*:[ ]*"[^"]*"' | head -n1 \
              | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        rawpath=$(printf '%s' "$ss" | grep -oE '"path"[ ]*:[ ]*"[^"]*"' | head -n1 \
                  | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        path="${rawpath%%\?*}"
        idx=$((idx+1))
        IN_ID[$idx]="$id"; IN_PORT[$idx]="$port"
        IN_NET[$idx]="${net:-unknown}"; IN_PATH[$idx]="$path"; IN_SS[$idx]="$ss"
    done < <(sqlite3 -separator '|' "$db" \
        "SELECT id, port, replace(replace(stream_settings, char(10), ' '), char(13), ' ') FROM inbounds;" \
        2>/dev/null)

    [ "$idx" -ge 1 ] || { warn "No inbounds found in database."; return 1; }

    echo -e "${INFO}Inbounds found:${RESET}"
    local n
    for n in $(seq 1 "$idx"); do
        echo -e "  ${C_ITEM_6}*${RESET} ${C_ITEM_4}port ${IN_PORT[$n]}${RESET} | ${C_ITEM_5}${IN_NET[$n]}${RESET} | ${C_ITEM_1}${IN_PATH[$n]:-(no path)}${RESET}"
    done
    echo -e "${INFO}Auto-selecting CDN-compatible inbounds (ws / httpupgrade / xhttp / grpc)...${RESET}"

    LOCATIONS=""
    local added=0 skipped_transport=0 skipped_path=0 skipped_dup=0
    USED_PORTS=$(ss -ltn 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': ' | tr '\n' ' ')
    TAKEN_PORTS=""; SEEN_PATHS=""

    # We will collect all SQL + host-insert operations then apply them together.
    local -a OP_IDS OP_FPORTS OP_NETS OP_PATHS OP_REMARKS OP_ALPNS
    local op_count=0

    local ltype fport inb_id remark alpn_json
    for n in $(seq 1 "$idx"); do
        port="${IN_PORT[$n]}"; net="${IN_NET[$n]}"
        path="${IN_PATH[$n]}"; inb_id="${IN_ID[$n]}"

        # ── Transport filter ────────────────────────────────────────────
        case "$net" in
            ws)                      ltype="upgrade" ;;
            httpupgrade)             ltype="upgrade" ;;
            xhttp|splithttp)         ltype="xhttp"   ;;
            grpc)
                # gRPC is proxied differently - we skip nginx location for grpc
                # but we still create the host entry in the DB for gRPC inbounds.
                ltype="grpc"
                ;;
            *)
                skipped_transport=$((skipped_transport+1)); continue ;;
        esac

        # ── Path filter (grpc uses serviceName, not path - still valid) ─
        if [ "$ltype" != "grpc" ]; then
            if [ -z "$path" ] || [ "$path" = "/" ]; then
                skipped_path=$((skipped_path+1)); continue
            fi
            case " $SEEN_PATHS " in
                *" $path "*) skipped_dup=$((skipped_dup+1)); continue ;;
            esac
            SEEN_PATHS="${SEEN_PATHS} ${path}"
        fi

        # ── Port conflict check ─────────────────────────────────────────
        fport="$port"
        if [ "$port" = "$HTTPS_PORT" ] || [ "$port" = "$HTTP_PORT" ]; then
            fport=$(free_port) || { err "No free local port available."; return 1; }
            warn "Port ${port} conflicts with Nginx -> moving to 127.0.0.1:${fport}"
        fi
        TAKEN_PORTS="${TAKEN_PORTS} ${fport}"

        # ── Determine remark (use network type as remark base) ───────────
        remark="${net}"

        # ── Determine ALPN ──────────────────────────────────────────────
        alpn_json=$(alpn_for_net "$net")

        # ── Store operation ─────────────────────────────────────────────
        op_count=$((op_count+1))
        OP_IDS[$op_count]="$inb_id"
        OP_FPORTS[$op_count]="$fport"
        OP_NETS[$op_count]="$net"
        OP_PATHS[$op_count]="$path"
        OP_REMARKS[$op_count]="$remark"
        OP_ALPNS[$op_count]="$alpn_json"

        # ── Add nginx location (skip grpc – nginx can't proxy gRPC here without http2) ─
        if [ "$ltype" != "grpc" ]; then
            LOCATIONS="${LOCATIONS}"$'\n'"$(make_location "$ltype" "$path" "$fport")"
        fi

        ok "Queued: ${net} port=${port}->127.0.0.1:${fport} | host: ${PRIMARY}:443 alpn=${alpn_json}"
        added=$((added+1))
    done

    echo ""
    echo -e "${INFO}Summary: ${C_ITEM_4}${added} queued${RESET} | skipped: ${skipped_transport} transport, ${skipped_path} no-path, ${skipped_dup} duplicate${RESET}"
    [ "$added" -ge 1 ] || { warn "No eligible inbounds found."; return 1; }

    echo ""
    echo -e "${WARN_BG} ACTION ${RESET} The following changes will be applied to ${added} inbound(s):"
    echo -e "  ${C_ITEM_3}• Set listen = 127.0.0.1${RESET}"
    echo -e "  ${C_ITEM_4}• Remove TLS / externalProxy from stream_settings${RESET}"
    echo -e "  ${C_ITEM_5}• Create a Host entry for each inbound (port 443, security=tls, sni=${PRIMARY})${RESET}"
    warn "A DB backup will be made first."
    local AP; ask_optional AP "Apply now?" "[y/N]"

    if is_yes "$AP"; then
        local bak="${db}.bak.$(date +%s)"
        cp "$db" "$bak" && ok "DB backed up: $bak" || { err "Backup failed."; return 1; }

        local m ok_count=0 fail_count=0
        for m in $(seq 1 "$op_count"); do
            local mid="${OP_IDS[$m]}"
            local mfport="${OP_FPORTS[$m]}"
            local mnet="${OP_NETS[$m]}"
            local mremark="${OP_REMARKS[$m]}"
            local malpn="${OP_ALPNS[$m]}"

            # 1. Move inbound to 127.0.0.1:fport + strip TLS
            if sqlite3 "$db" \
                "UPDATE inbounds SET listen='127.0.0.1', port=${mfport} WHERE id=${mid};" \
                2>/tmp/sql_err.log; then
                ok "  inbound id=${mid}: listen=127.0.0.1 port=${mfport}"
            else
                err "  inbound id=${mid}: SQL update failed"; cat /tmp/sql_err.log
                fail_count=$((fail_count+1)); continue
            fi

            # 2. Strip TLS / externalProxy from stream_settings
            local strip_out
            strip_out=$(strip_tls_py "$db" "$mid" 2>&1)
            if echo "$strip_out" | grep -q "^OK"; then
                ok "  inbound id=${mid}: stream_settings cleaned"
            else
                warn "  inbound id=${mid}: stream_settings strip warning: $strip_out"
            fi

            # 3. Create host entry in hosts table
            local host_out
            host_out=$(insert_host_py "$db" "$mid" "$mremark" "$PRIMARY" "443" "$PRIMARY" "$malpn" 2>&1)
            if echo "$host_out" | grep -q "^OK"; then
                ok "  inbound id=${mid}: host created -> ${PRIMARY}:443 sni=${PRIMARY} alpn=${malpn}"
                ok_count=$((ok_count+1))
            else
                err "  inbound id=${mid}: host insert failed: $host_out"
                fail_count=$((fail_count+1))
            fi
        done

        echo ""
        ok "Done: ${ok_count} hosts created, ${fail_count} failures."
        if [ "$fail_count" -gt 0 ]; then
            warn "Some operations failed. Check errors above. Backup is at: $bak"
        fi
        systemctl restart x-ui 2>/dev/null && ok "x-ui restarted." \
            || warn "Could not restart x-ui. Run: x-ui restart"
    else
        warn "Skipped DB changes. Set listen=127.0.0.1 and add hosts manually in panel."
    fi
    return 0
}

# ── Gather inputs ─────────────────────────────────────────────────────────
gather_inputs() {
    ask DOMAIN "Domain" "(e.g. ex.example.com)"
    DOMAIN=$(printf '%s' "$DOMAIN" | tr ',' ' ' | tr -s ' ' | sed -E 's/^ +| +$//g')
    PRIMARY=$(printf '%s' "$DOMAIN" | awk '{print $1}')

    ask_port HTTPS_PORT "HTTPS listen port" 443
    ask_port HTTP_PORT  "HTTP listen port"  80

    ask_file SSL_CERT "Full path to SSL certificate (fullchain.pem)"
    ask_file SSL_KEY  "Full path to SSL private key (privkey.pem)"

    ask_optional BEHIND_CF "Behind Cloudflare CDN? (restore real visitor IP)" "[y/N]"

    LOCATIONS=""
    echo -e "${INFO}Inbound configuration:${RESET}"
    echo -e "  ${C_ITEM_1}1)${RESET} ${C_ITEM_4}Auto (read from x-ui database + create hosts)${RESET}"
    echo -e "  ${C_ITEM_2}2)${RESET} ${C_ITEM_5}Manual entry${RESET}"
    ask_choice DISC "Selection" "1|2"

    if [ "$DISC" = "1" ] && auto_build_locations; then
        ok "Locations built automatically."
    else
        [ "$DISC" = "1" ] && warn "Auto-build failed, switching to manual."
        ask_number NIN "How many inbounds?"
        local i=1
        while [ "$i" -le "$NIN" ]; do
            echo -e "${INFO}--- Inbound #${i} ---${RESET}"
            ask P_PATH "Path" "(e.g. /ws${i})"
            [ "${P_PATH:0:1}" = "/" ] || P_PATH="/$P_PATH"
            ask_number P_PORT "Local Xray port"
            echo -e "${INFO}Transport:${RESET}"
            echo -e "  ${C_ITEM_1}1)${RESET} WebSocket  ${C_ITEM_2}2)${RESET} HTTPUpgrade  ${C_ITEM_3}3)${RESET} XHTTP"
            ask_choice P_TYPE "Selection" "1|2|3"
            case "$P_TYPE" in
                1|2) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location upgrade "$P_PATH" "$P_PORT")" ;;
                3)   LOCATIONS="${LOCATIONS}"$'\n'"$(make_location xhttp   "$P_PATH" "$P_PORT")" ;;
            esac
            i=$((i+1))
        done
    fi

    echo -e "${INFO}Camouflage site:${RESET}"
    echo -e "  ${C_ITEM_1}1)${RESET} ${C_ITEM_4}Reverse-proxy to existing website${RESET}"
    echo -e "  ${C_ITEM_2}2)${RESET} ${C_ITEM_5}Serve local HTML file${RESET}"
    ask_choice CAMO "Selection" "1|2"

    if [ "$CAMO" = "1" ]; then
        ask PROXY_URL "Website URL to proxy" "(e.g. example.com or https://example.com)"
        PROXY_URL=$(normalize_url "$PROXY_URL")
        PROXY_SCHEME=$(printf '%s' "$PROXY_URL" | grep -oE '^https?')
        PROXY_HOST=$(printf '%s' "$PROXY_URL" | sed -E 's#^https?://##; s#/.*##')
        PROXY_BASEPATH=$(printf '%s' "$PROXY_URL" | sed -E 's#^https?://[^/]*##')
        [ -z "$PROXY_BASEPATH" ] && PROXY_BASEPATH="/"
        [ "$PROXY_SCHEME" = "http" ] && warn "HTTP origin over HTTPS may cause mixed content issues."
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

# ── Camouflage reverse-proxy block ────────────────────────────────────────
_build_camo_block() {
    local js_file="/tmp/goldip_js_$$.js"
    cat > "$js_file" <<JSEOF
<script>(function(){var H="PROXY_HOST_PH",S="PROXY_SCHEME_PH";var r1=new RegExp(S+"://"+H.replace(/\./g,"\\."),\"g\");var r2=new RegExp("//"+H.replace(/\./g,"\\."),\"g\");function c(u){return typeof u==="string"?u.replace(r1,"").replace(r2,""):u;}var oF=window.fetch;window.fetch=function(u,o){return oF.call(this,c(u),o);};var oX=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){return oX.apply(this,[m,c(u)].concat(Array.prototype.slice.call(arguments,2)));};var oP=history.pushState,oR=history.replaceState;history.pushState=function(s,t,u){return oP.call(this,s,t,c(u));};history.replaceState=function(s,t,u){return oR.call(this,s,t,c(u));};try{var dl=Object.getOwnPropertyDescriptor(window.location,"href");if(dl&&dl.set){Object.defineProperty(window.location,"href",{set:function(v){window.history.replaceState(null,"",c(v));},get:dl.get,configurable:true});}}catch(e){}document.addEventListener("click",function(e){var a=e.target.closest("a");if(!a)return;var h=a.getAttribute("href")||"";if(r1.test(h)||r2.test(h)){e.preventDefault();window.history.pushState(null,"",c(h));}},true);})();</script>
JSEOF
    local js_inline
    js_inline=$(sed "s|PROXY_HOST_PH|${PROXY_HOST}|g; s|PROXY_SCHEME_PH|${PROXY_SCHEME}|g" "$js_file" | tr -d '\n')
    rm -f "$js_file"

    CAMO_BLOCK="# Camouflage reverse-proxy - gzip off for sub_filter
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

# ── Write nginx config ────────────────────────────────────────────────────
write_config() {
    mkdir -p "$NGINX_CONF_DIR"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null

    is_yes "${BEHIND_CF:-}" && write_cf_realip

    if ! nginx -V 2>&1 | grep -q 'http_sub_module'; then
        warn "http_sub_module not found. Installing nginx-extras..."
        apt-get install -y nginx-extras >/dev/null 2>&1 \
            && ok "nginx-extras installed." \
            || warn "Could not install nginx-extras."
    fi

    local conf="${NGINX_CONF_DIR}/${PRIMARY}.conf"
    {
        echo "server {"
        echo "    listen ${HTTP_PORT};"
        echo "    server_name ${DOMAIN};"
        echo "    return 301 https://\$host\$request_uri;"
        echo "}"
        echo ""
        echo "server {"
        echo "    listen ${HTTPS_PORT} ssl;"
        echo "    server_name ${DOMAIN};"
        echo ""
        echo "    ssl_certificate     ${SSL_CERT};"
        echo "    ssl_certificate_key ${SSL_KEY};"
        echo "    ssl_protocols TLSv1.2 TLSv1.3;"
        echo "    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;"
        echo "    ssl_prefer_server_ciphers off;"
        echo "    ssl_session_cache shared:SSL:10m;"
        echo "    ssl_session_timeout 1d;"
        echo ""
        echo "    add_header X-Content-Type-Options nosniff;"
        echo "    add_header X-Frame-Options SAMEORIGIN;"
        echo "    add_header Referrer-Policy no-referrer-when-downgrade;"
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
        ok "Nginx running for: ${DOMAIN}"
        echo -e "${INFO}URL: https://${PRIMARY}:${HTTPS_PORT}/${RESET}"
    else
        err "Config test failed:"; cat /tmp/nginx_test.log; return 1
    fi
}

do_install() {
    install_nginx; ensure_sqlite3; gather_inputs
    write_config || return 1; enable_persistence silent
}

# ── Full Nginx uninstall ──────────────────────────────────────────────────
full_uninstall() {
    echo -e "${ERR_BG} WARNING ${RESET} \033[1;31mThis will COMPLETELY remove Nginx and all GoldIP configs!\033[0m"
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
    ok "Drop-in configs removed."

    rm -f "${NGINX_CONF_DIR}/00-cloudflare-realip.conf"
    rm -f "${NGINX_CONF_DIR}/00-arvan-realip.conf"

    apt-get purge -y nginx nginx-common nginx-full nginx-extras nginx-core 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    ok "Nginx packages removed."

    rm -rf /etc/nginx
    rm -rf /var/log/nginx
    rm -rf /var/www/goldip
    rm -f /var/lock/nginx.lock 2>/dev/null || true
    rm -f /run/nginx.pid 2>/dev/null || true
    ok "Nginx fully uninstalled and all configs cleaned."
}

# ── Domain config remove only ─────────────────────────────────────────────
uninstall_domain() {
    local D
    ask D "Domain config to remove" "(e.g. ex.example.com)"
    rm -f "${NGINX_CONF_DIR}/${D}.conf"
    if command -v nginx >/dev/null 2>&1 && nginx -t 2>/dev/null; then
        systemctl reload nginx && ok "Config for ${D} removed and nginx reloaded."
    else
        ok "Config for ${D} removed."
    fi
}

# ── Service control ───────────────────────────────────────────────────────
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

# ── Logs ──────────────────────────────────────────────────────────────────
colorize_error_line() {
    local line="$1"
    printf '%s' "$line" | grep -qiE '\[(error|crit|alert|emerg)\]' \
        && { echo -e "${ERR_BG} ERR ${RESET} $line"; return; }
    printf '%s' "$line" | grep -qiE '\[warn\]' \
        && { echo -e "${WARN_BG} WARN ${RESET} $line"; return; }
    printf '%s' "$line" | grep -qiE '\[notice\]' \
        && { echo -e "${OK_BG} NOTE ${RESET} $line"; return; }
    echo -e "${C_ITEM_3}$line${RESET}"
}
colorize_access_line() {
    local line="$1" code
    code=$(printf '%s' "$line" | grep -oE '" [1-5][0-9][0-9] ' | head -n1 | tr -dc '0-9')
    [ -n "$code" ] || code=$(printf '%s' "$line" | grep -oE ' [1-5][0-9][0-9] ' | head -n1 | tr -dc '0-9')
    case "$code" in
        5*) echo -e "${ERR_BG} ${code} ${RESET} $line" ;;
        4*) echo -e "${WARN_BG} ${code} ${RESET} $line" ;;
        2*|3*) echo -e "${OK_BG} ${code} ${RESET} $line" ;;
        *) echo -e "${C_ITEM_6}$line${RESET}" ;;
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
        echo -e "  ${C_ITEM_6}${n})${RESET} ${C_ITEM_4}${LOGS[$n]}${RESET} ${C_ITEM_5}(${size:-0})${RESET}"
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

# ── CDN IP ranges ─────────────────────────────────────────────────────────
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

# ── Trusted domain & service-port auto-detection ──────────────────────────
resolve_domain_ips_v4() {
    local domain="$1" ips=""
    if command -v getent >/dev/null 2>&1; then
        ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    fi
    if [ -z "$ips" ] && command -v dig >/dev/null 2>&1; then
        ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    fi
    if [ -z "$ips" ] && command -v host >/dev/null 2>&1; then
        ips=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF}')
    fi
    printf '%s\n' "$ips"
}
resolve_domain_ips_v6() {
    local domain="$1" ips=""
    if command -v getent >/dev/null 2>&1; then
        ips=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    fi
    if [ -z "$ips" ] && command -v dig >/dev/null 2>&1; then
        ips=$(dig +short AAAA "$domain" 2>/dev/null)
    fi
    if [ -z "$ips" ] && command -v host >/dev/null 2>&1; then
        ips=$(host -t AAAA "$domain" 2>/dev/null | awk '/has IPv6 address/ {print $NF}')
    fi
    printf '%s\n' "$ips"
}

whitelist_goldip() {
    local v4 v6 ip hit=0
    v4=$(resolve_domain_ips_v4 "$GOLDIP_DOMAIN")
    v6=$(resolve_domain_ips_v6 "$GOLDIP_DOMAIN")
    if [ -z "$v4" ] && [ -z "$v6" ]; then
        warn "Could not resolve ${GOLDIP_DOMAIN} - skipping whitelist."
        return 1
    fi
    for ip in $v4 $v6; do
        ufw allow from "$ip" >/dev/null 2>&1 \
            && { ok "Whitelisted ${GOLDIP_DOMAIN} (${ip}) - all ports/protocols allowed."; hit=1; }
    done
    [ "$hit" -eq 1 ] || warn "Failed to add ufw rule(s) for ${GOLDIP_DOMAIN}."
    warn "Note: if ${GOLDIP_DOMAIN} is CDN-proxied (orange-cloud), this resolves to a shared CDN IP."
}

open_xui_panel_and_sub_ports() {
    local db; db=$(find_xui_db)
    if [ -z "$db" ]; then
        warn "x-ui.db not found - skipping panel/subscription auto-open."
        return 1
    fi
    ensure_sqlite3 || return 1

    local webport subport subenable
    webport=$(sqlite3 "$db"   "SELECT value FROM settings WHERE key='webPort';"    2>/dev/null | tr -d '[:space:]')
    subport=$(sqlite3 "$db"   "SELECT value FROM settings WHERE key='subPort';"    2>/dev/null | tr -d '[:space:]')
    subenable=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='subEnable';"  2>/dev/null | tr -d '[:space:]')

    if is_number "$webport"; then
        ufw allow "${webport}/tcp" >/dev/null 2>&1 && ok "Panel port ${webport}/tcp opened (auto-detected from x-ui.db)."
    else
        warn "Panel port (webPort) not found in x-ui database - open it manually if needed."
    fi

    case "$subenable" in
        true|True|TRUE|1)
            if is_number "$subport"; then
                ufw allow "${subport}/tcp" >/dev/null 2>&1 && ok "Subscription port ${subport}/tcp opened (auto-detected from x-ui.db)."
            else
                warn "Subscription is enabled but its port (subPort) was not found in the database."
            fi
            ;;
        *)
            warn "Subscription service looks disabled (or unset) - leaving its port closed."
            ;;
    esac
}

# ── Firewall setup ────────────────────────────────────────────────────────
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
    echo -e "  ${C_ITEM_1}1)${RESET} Cloudflare  ${C_ITEM_2}2)${RESET} ArvanCloud  ${C_ITEM_3}3)${RESET} Both  ${C_ITEM_6}4)${RESET} Custom"
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
    ask_port FW_HTTPS "HTTPS port" 443
    ask_port FW_HTTP  "HTTP port" 80
    ask_port_optional TUN_PORT "Tunnel port (e.g. 8443)"
    [ -n "$TUN_PORT" ] && ask_optional FOREIGN_IP "Tunnel allowed from IP" "(blank = any)"
    [ -f /etc/default/ufw ] && sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw 2>/dev/null
    warn "Resetting firewall..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1; ok "SSH on ${SSH_PORT}/tcp"

    whitelist_goldip
    open_xui_panel_and_sub_ports

    local cidr
    for cidr in $RANGES; do
        ufw allow from "$cidr" to any port "$FW_HTTPS" proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port "$FW_HTTP"  proto tcp >/dev/null 2>&1
    done
    for cidr in $RANGES6; do
        ufw allow from "$cidr" to any port "$FW_HTTPS" proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port "$FW_HTTP"  proto tcp >/dev/null 2>&1
    done
    ok "Ports ${FW_HTTPS},${FW_HTTP} allowed from CDN ranges."
    if [ -n "$TUN_PORT" ]; then
        [ -n "$FOREIGN_IP" ] \
            && { ufw allow from "$FOREIGN_IP" to any port "$TUN_PORT" proto tcp >/dev/null 2>&1
                 ok "Tunnel ${TUN_PORT} from ${FOREIGN_IP}"; } \
            || { ufw allow "${TUN_PORT}/tcp" >/dev/null 2>&1
                 warn "Tunnel ${TUN_PORT} open to ANY."; }
    fi
    ufw --force enable >/dev/null 2>&1; ok "Firewall enabled."
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
        warn "CF only forwards ports: 443,2053,2083,2087,2096,8443"
        warn "Set CF SSL mode to Full (not Flexible)."
    }
    echo -e "${INFO}--- Active rules ---${RESET}"; ufw status numbered
}

firewall_status() {
    command -v ufw >/dev/null 2>&1 && ufw status verbose || warn "ufw not installed."
}

# ── Watchdog ──────────────────────────────────────────────────────────────
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
    warn "To stop: systemctl disable --now goldip-watchdog.timer"
}

# ── Persistence ───────────────────────────────────────────────────────────
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
    systemctl daemon-reload >/dev/null 2>&1
    ok "systemd reloaded."
    [ "$mode" = "silent" ] && return
    if systemctl list-unit-files 2>/dev/null | grep -q '^goldip-watchdog\.timer'; then
        ok "Watchdog already active."
    else
        local WD; ask_optional WD "Install 1-min watchdog?" "[y/N]"
        is_yes "$WD" && install_watchdog
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────
menu() {
    while true; do
        clear
        echo -e "${TITLE}"; header; echo -e "${RESET}"

        # Each menu line has its own unique colour. Green/Red only for ok()/err().
        echo -e "  ${C_ITEM_1}1)${RESET}  ${C_ITEM_1}Install / Config website${RESET}"
        echo -e "  ${C_ITEM_2}2)${RESET}  ${C_ITEM_2}Start Nginx${RESET}"
        echo -e "  ${C_ITEM_3}3)${RESET}  ${C_ITEM_3}Stop Nginx${RESET}"
        echo -e "  ${C_ITEM_4}4)${RESET}  ${C_ITEM_4}Restart Nginx${RESET}"
        echo -e "  ${C_ITEM_5}5)${RESET}  ${C_ITEM_5}Reload Nginx${RESET}"
        echo -e "  ${C_ITEM_6}6)${RESET}  ${C_ITEM_6}Status${RESET}"
        echo -e "  ${C_ITEM_7}7)${RESET}  ${C_ITEM_7}View logs${RESET}"
        echo -e "  ${C_ITEM_8}8)${RESET}  ${C_ITEM_8}Remove domain config${RESET}"
        echo -e "  ${C_ITEM_9}9)${RESET}  ${C_ITEM_9}Setup firewall${RESET}"
        echo -e "  ${C_ITEM_10}10)${RESET} ${C_ITEM_10}Firewall status${RESET}"
        echo -e "  ${C_ITEM_11}11)${RESET} ${C_ITEM_11}Fix auto-start (persistence)${RESET}"
        echo -e "  ${C_ITEM_12}12)${RESET} ${C_ITEM_12}FULL Nginx uninstall + cleanup${RESET}"
        echo -e "  ${C_ITEM_0}0)${RESET}  ${C_ITEM_0}Exit${RESET}"

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

# ── Entry ─────────────────────────────────────────────────────────────────
require_root
menu
