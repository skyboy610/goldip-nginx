#!/bin/bash
# ============================================================
#  GoldIP Nginx Camouflage Installer & Manager  v3.5 (Uncut)
#  - Hosts API (No externalProxy) & Hosts Cleanup
#  - xHTTP xPadding Auto-Injection
#  - gRPC / Hysteria / TCP / UDP Full Support
#  - Hardened Nginx Security Headers & Auto-SSL
#  - Full Management Tools & Manual Mode Restored
# ============================================================
set -uo pipefail

RESET='\033[0m'
M1='\033[1;36m'; M2='\033[1;35m'; M3='\033[1;34m'; M4='\033[1;32m'
M5='\033[1;33m'; M6='\033[1;31m'; M7='\033[1;95m'; M8='\033[1;96m'
M9='\033[1;92m'; M10='\033[1;93m'; M11='\033[1;94m'; M12='\033[1;91m'
TITLE='\033[1;36m'; INFO='\033[1;34m'
OK_BG='\033[42m\033[97m'; WARN_BG='\033[43m\033[97m'; ERR_BG='\033[41m\033[97m'

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
        [ -n "$__hint" ] && echo -e "${__c}${__q} ${__hint}:${RESET}" || echo -e "${__c}${__q}:${RESET}"
        read -r __ans
        [ -n "$__ans" ] && { printf -v "$__var" '%s' "$__ans"; return 0; }
        warn "This field can't be empty."
    done
}
ask_optional() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans __c
    nextcolor; __c="$CURCOLOR"
    [ -n "$__hint" ] && echo -e "${__c}${__q} ${__hint}:${RESET}" || echo -e "${__c}${__q}:${RESET}"
    read -r __ans; printf -v "$__var" '%s' "$__ans"
}
ask_number() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans __c
    while true; do
        nextcolor; __c="$CURCOLOR"
        [ -n "$__hint" ] && echo -e "${__c}${__q} ${__hint}:${RESET}" || echo -e "${__c}${__q}:${RESET}"
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
        echo -e "${__c}${__q}:${RESET}"; read -r __ans
        [ -z "$__ans" ] && { warn "Path can't be empty."; continue; }
        [ -f "$__ans" ] || { err "File not found: $__ans"; continue; }
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}
ask_choice() {
    local __var="$1" __q="$2" __valid="$3" __ans __c
    while true; do
        nextcolor; __c="$CURCOLOR"
        echo -e "${__c}${__q} [${__valid//|//}]:${RESET}"; read -r __ans
        printf '%s' "$__ans" | grep -qiE "^(${__valid})$" && { printf -v "$__var" '%s' "$__ans"; return 0; }
        warn "Invalid choice."
    done
}
is_yes() { case "$1" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac; }

strip_scheme() { printf '%s' "$1" | sed -E 's#^https?://##; s#/.*##; s/^[[:space:]]+//; s/[[:space:]]+$//'; }
strip_port() { printf '%s' "$1" | sed -E 's/:[0-9]+$//'; }

# ---------------- Header & Essentials ----------------
header() {
cat <<'EOF'
==========================================================
   ____       _     _ ___ ____
  / ___| ___ | | __| |_ _|  _ \
 | |  _ / _ \| |/ _` || || |_) |
 | |_| | (_) | | (_| || ||  __/
  \____|\___/|_|\__,_|___|_|
    N G I N X   C A M O U F L A G E   v3.5 (Uncut)
==========================================================
EOF
}

require_root() { [ "$(id -u)" -eq 0 ] || { err "Run this script as root."; exit 1; }; }

ensure_sqlite3() { command -v sqlite3 >/dev/null 2>&1 || apt-get install -y sqlite3 >/dev/null 2>&1; }

install_nginx() {
    command -v nginx >/dev/null 2>&1 && { ok "Nginx already installed."; return 0; }
    apt-get update -y >/dev/null 2>&1 && apt-get install -y nginx >/dev/null 2>&1 || err "Nginx install failed."
}

# ---------------- Location Builder ----------------
make_location() {
    local t="$1" p="$2" port="$3"
    [ "${p:0:1}" != "/" ] && p="/$p"
    if [ "$t" = "grpc" ]; then
        printf '    location %s {\n' "$p"
        printf '        grpc_pass grpc://127.0.0.1:%s;\n' "$port"
        printf '        grpc_set_header X-Real-IP $remote_addr;\n'
        printf '        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
        printf '        grpc_set_header X-Forwarded-Proto $scheme;\n'
        printf '        grpc_set_header Host $host;\n'
        printf '        grpc_read_timeout 1h;\n'
        printf '        grpc_send_timeout 1h;\n'
        printf '        client_max_body_size 0;\n'
        printf '    }\n'
    elif [ "$t" = "xhttp" ]; then
        printf '    location %s {\n' "$p"
        printf '        proxy_pass http://127.0.0.1:%s;\n' "$port"
        printf '        proxy_http_version 1.1;\n'
        printf '        proxy_set_header Host $host;\n'
        printf '        proxy_set_header X-Real-IP $remote_addr;\n'
        printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
        printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
        printf '        proxy_set_header Sec-Fetch-Mode cors;\n'
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
        printf '        proxy_read_timeout 300s;\n'
        printf '        proxy_send_timeout 300s;\n'
        printf '    }\n'
    fi
}

free_port() {
    local p
    for p in $(seq 20000 29999); do
        case " $USED_PORTS " in *" $p "*) continue ;; esac
        case " $TAKEN_PORTS " in *" $p "*) continue ;; esac
        echo "$p"; return 0
    done; return 1
}

# ---------------- Database Python Scripts ----------------
alpn_for_net() {
    case "$1" in
        grpc) printf '["h2"]' ;;
        xhttp|splithttp) printf '["http/1.1","h2"]' ;;
        *) printf '["http/1.1"]' ;;
    esac
}

insert_host_py() {
    python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PYEOF'
import sqlite3, sys, time
db_path, inbound_id, remark, address, port, sni, alpn_json = sys.argv[1:8]
now_ms = int(time.time() * 1000)
try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("""
        INSERT INTO hosts (
            inbound_id, sort_order, remark, server_description, is_disabled, is_hidden,
            address, port, security, sni, host_header, path, alpn, fingerprint, override_sni_from_address,
            keep_sni_blank, allow_insecure, created_at, updated_at
        ) VALUES (?, 0, ?, '', 0, 0, ?, ?, 'tls', ?, '', '', ?, 'chrome', 1, 0, 0, ?, ?)
    """, (int(inbound_id), remark, address, int(port), sni, alpn_json, now_ms, now_ms))
    con.commit(); con.close(); print("OK"); sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)
PYEOF
}

strip_tls_py() {
    python3 - "$1" "$2" "$3" <<'PYEOF'
import sqlite3, json, sys
try:
    con = sqlite3.connect(sys.argv[1]); cur = con.cursor(); inb_id = int(sys.argv[2]); net = sys.argv[3]
    cur.execute("SELECT stream_settings FROM inbounds WHERE id=?", (inb_id,))
    row = cur.fetchone()
    if row and row[0]:
        ss = json.loads(row[0])
        ss["security"] = "none"
        for k in ("tlsSettings", "realitySettings", "externalProxy", "externalProxySettings"): ss.pop(k, None)
        
        if net in ("xhttp", "splithttp"):
            s_key = net + "Settings"
            if s_key not in ss: ss[s_key] = {}
            if "extra" not in ss[s_key]: ss[s_key]["extra"] = {}
            ss[s_key]["extra"]["xpaddingBytes"] = "100-1000"
            
        cur.execute("UPDATE inbounds SET stream_settings=? WHERE id=?", (json.dumps(ss), inb_id))
        con.commit()
    con.close(); print("OK"); sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)
PYEOF
}

# ---------------- SSL Discovery ----------------
find_certificate_for_domain() {
    local domain; domain=$(strip_port "${1:-}")
    [ -n "$domain" ] || return 1
    if [ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
        printf '%s|%s' "/etc/letsencrypt/live/${domain}/fullchain.pem" "/etc/letsencrypt/live/${domain}/privkey.pem"; return 0
    fi
    for d in /etc/letsencrypt/live/"${domain}"-[0-9]*/; do
        [ -f "${d}fullchain.pem" ] && [ -f "${d}privkey.pem" ] && { printf '%s|%s' "${d}fullchain.pem" "${d}privkey.pem"; return 0; }
    done
    for d in "${HOME}/.acme.sh/${domain}"*/; do
        [ -f "${d}fullchain.cer" ] && [ -f "${d}${domain}.key" ] && { printf '%s|%s' "${d}fullchain.cer" "${d}${domain}.key"; return 0; }
    done
    return 1
}

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
    ok "Certbot renewal hook installed."
}

# ---------------- Auto Build Locations ----------------
auto_build_locations() {
    local db=""; for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do [ -f "$c" ] && db="$c" && break; done
    [ -z "$db" ] && return 1
    ok "Reading inbounds from: $db"

    local idx=0 id port ss net path rawpath
    local -a IN_ID IN_PORT IN_NET IN_PATH IN_SS
    while IFS='|' read -r id port ss; do
        [ -n "$port" ] || continue
        net=$(printf '%s' "$ss" | grep -oE '"network"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        if [ "$net" = "grpc" ]; then
            rawpath=$(printf '%s' "$ss" | grep -oE '"serviceName"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        else
            rawpath=$(printf '%s' "$ss" | grep -oE '"path"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        fi
        path="${rawpath%%\?*}"
        idx=$((idx+1))
        IN_ID[$idx]="$id"; IN_PORT[$idx]="$port"; IN_NET[$idx]="${net:-unknown}"; IN_PATH[$idx]="$path"; IN_SS[$idx]="$ss"
    done < <(sqlite3 -separator '|' "$db" "SELECT id, port, replace(replace(stream_settings, char(10), ' '), char(13), ' ') FROM inbounds;" 2>/dev/null)

    LOCATIONS=""; USED_PORTS=$(ss -ltn 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': ' | tr '\n' ' ')
    TAKEN_PORTS=""; local added=0 skipped=0
    local -a OP_IDS OP_FPORTS OP_NETS OP_PATHS OP_ALPNS
    local op_count=0 ltype fport

    for n in $(seq 1 "$idx"); do
        net="${IN_NET[$n]}"; port="${IN_PORT[$n]}"; path="${IN_PATH[$n]}"; id="${IN_ID[$n]}"
        case "$net" in
            ws|httpupgrade) ltype="upgrade" ;;
            xhttp|splithttp) ltype="xhttp" ;;
            grpc) ltype="grpc" ;;
            *) skipped=$((skipped+1)); ok "Skipped non-CDN protocol: ${net} (Port ${port})"; continue ;;
        esac

        [ -z "$path" ] || [ "$path" = "/" ] && continue
        fport="$port"
        if [ "$port" = "$HTTPS_PORT" ] || [ "$port" = "$HTTP_PORT" ]; then fport=$(free_port); fi
        TAKEN_PORTS="${TAKEN_PORTS} ${fport}"
        
        op_count=$((op_count+1))
        OP_IDS[$op_count]="$id"; OP_FPORTS[$op_count]="$fport"; OP_NETS[$op_count]="$net"
        OP_PATHS[$op_count]="$path"; OP_ALPNS[$op_count]=$(alpn_for_net "$net")
        
        LOCATIONS="${LOCATIONS}"$'\n'"$(make_location "$ltype" "$path" "$fport")"
        ok "Queued: ${net} ${path} -> 127.0.0.1:${fport} (Host: ${PRIMARY}:443)"
        added=$((added+1))
    done

    [ "$added" -eq 0 ] && { warn "No CDN-compatible inbounds found."; return 1; }
    local AP; ask_optional AP "Apply DB changes (Inject xPadding + Rebuild Hosts)?" "[y/N]"
    if is_yes "$AP"; then
        cp "$db" "${db}.bak.$(date +%s)"
        for m in $(seq 1 "$op_count"); do
            mid="${OP_IDS[$m]}"; mfport="${OP_FPORTS[$m]}"; mnet="${OP_NETS[$m]}"; malpn="${OP_ALPNS[$m]}"
            sqlite3 "$db" "UPDATE inbounds SET listen='127.0.0.1', port=${mfport} WHERE id=${mid};"
            strip_tls_py "$db" "$mid" "$mnet" >/dev/null
            sqlite3 "$db" "DELETE FROM hosts WHERE inbound_id=${mid};"
            insert_host_py "$db" "$mid" "$mnet" "$PRIMARY" "443" "$PRIMARY" "$malpn" >/dev/null
        done
        ok "Database updated! Restarting x-ui..."; systemctl restart x-ui
    fi
    return 0
}

# ---------------- Camouflage Block ----------------
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

# ---------------- Setup Flow ----------------
gather_inputs() {
    echo -e "${INFO}=== Panel Configuration ===${RESET}"
    ask RAW_PANEL "Panel Domain / IP" "(e.g. panel.example.com)"
    PANEL_DOMAIN=$(strip_scheme "$RAW_PANEL"); PANEL_DOMAIN=$(strip_port "$PANEL_DOMAIN")
    ask_port PANEL_PORT "Panel Port" 2053

    echo -e "${INFO}=== CDN Configuration ===${RESET}"
    ask RAW_CDN "CDN Domain" "(e.g. cdn.example.com)"
    CDN_DOMAIN=$(strip_scheme "$RAW_CDN"); PRIMARY="$CDN_DOMAIN"
    ask_port HTTPS_PORT "HTTPS Port" 443
    ask_port HTTP_PORT  "HTTP Port"  80

    echo -e "${INFO}=== TLS Certificate ===${RESET}"
    local FOUND AUTO_CERT="" AUTO_KEY=""
    FOUND="$(find_certificate_for_domain "$CDN_DOMAIN")" && IFS='|' read -r AUTO_CERT AUTO_KEY <<<"$FOUND"
    [ -z "$AUTO_CERT" ] && FOUND="$(find_certificate_for_domain "$PANEL_DOMAIN")" && IFS='|' read -r AUTO_CERT AUTO_KEY <<<"$FOUND"
    
    if [ -n "$AUTO_CERT" ] && [ -f "$AUTO_CERT" ]; then
        ok "Found cert: ${AUTO_CERT}"
        local USE; ask_optional USE "Use this cert?" "[Y/n]"
        case "$USE" in n|N|no) ask_file SSL_CERT "Cert Path"; ask_file SSL_KEY "Key Path" ;; *) SSL_CERT="$AUTO_CERT"; SSL_KEY="$AUTO_KEY" ;; esac
    else
        ask_file SSL_CERT "Cert Path (fullchain)"; ask_file SSL_KEY "Key Path (privkey)"
    fi
    ensure_cert_renew_hook "$SSL_CERT"

    ask_optional BEHIND_CF "Behind Cloudflare CDN? (restore real visitor IP)" "[y/N]"

    echo -e "${INFO}=== Inbounds ===${RESET}"
    local DISC; ask_choice DISC "1) Auto (DB)  2) Manual" "1|2"
    
    [ "$DISC" = "1" ] && { auto_build_locations || warn "Auto-build failed or skipped. Switching to manual."; }
    
    # Restore Manual Mode Loop
    if [ "$DISC" = "2" ] || [ -z "$LOCATIONS" ]; then
        ask_number NIN "How many CDN inbounds to add to Nginx?"
        local i=1
        while [ "$i" -le "$NIN" ]; do
            echo -e "${INFO}--- Inbound #${i} ---${RESET}"
            ask P_PATH "Path / ServiceName" "(e.g. /ws${i} or my-grpc-svc)"
            [ "${P_PATH:0:1}" = "/" ] || P_PATH="/$P_PATH"
            ask_number P_PORT "Local Xray port"
            echo -e "${INFO}Transport:${RESET}"
            echo -e "  ${M1}1)${RESET} WebSocket / HTTPUpgrade  ${M2}2)${RESET} XHTTP  ${M3}3)${RESET} gRPC"
            ask_choice P_TYPE "Selection" "1|2|3"
            case "$P_TYPE" in
                1) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location upgrade "$P_PATH" "$P_PORT")" ;;
                2) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location xhttp "$P_PATH" "$P_PORT")" ;;
                3) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location grpc "$P_PATH" "$P_PORT")" ;;
            esac
            i=$((i+1))
        done
    fi

    echo -e "${INFO}=== Camouflage ===${RESET}"
    ask_choice CAMO "1) Reverse Proxy  2) Local HTML" "1|2"
    if [ "$CAMO" = "1" ]; then
        ask PROXY_URL "Website to proxy (e.g. example.com)"
        PROXY_HOST=$(strip_scheme "$PROXY_URL"); PROXY_SCHEME="https"
        PROXY_BASEPATH=$(printf '%s' "$PROXY_URL" | sed -E 's#^https?://[^/]*##')
        [ -z "$PROXY_BASEPATH" ] && PROXY_BASEPATH="/"
        _build_camo_block
    else
        ask_file HTML_FILE "Path to index.html"
        mkdir -p "$CAMO_ROOT"; cp "$HTML_FILE" "$CAMO_ROOT/index.html"
        CAMO_BLOCK="location / { root ${CAMO_ROOT}; index index.html; }"
    fi
}

write_config() {
    mkdir -p "$NGINX_CONF_DIR"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null

    is_yes "${BEHIND_CF:-}" && write_cf_realip

    nginx -V 2>&1 | grep -q 'http_sub_module' || {
        apt-get install -y nginx-extras >/dev/null 2>&1
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
        echo "    listen ${HTTPS_PORT} ssl http2;"
        echo "    server_name ${CDN_DOMAIN};"
        echo "    ssl_certificate     ${SSL_CERT};"
        echo "    ssl_certificate_key ${SSL_KEY};"
        echo "    ssl_protocols TLSv1.2 TLSv1.3;"
        echo "    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;"
        echo "    ssl_prefer_server_ciphers off;"
        
        echo "    server_tokens off;"
        echo "    add_header X-Content-Type-Options nosniff always;"
        echo "    add_header X-Frame-Options SAMEORIGIN always;"
        echo "    add_header Referrer-Policy no-referrer-when-downgrade always;"
        echo "    add_header Strict-Transport-Security \"max-age=63072000; includeSubDomains\" always;"
        echo "    add_header X-XSS-Protection \"0\" always;"
        
        echo "    access_log /var/log/nginx/${PRIMARY}.access.log;"
        echo "    error_log  /var/log/nginx/${PRIMARY}.error.log;"
        
        printf '%s\n' "${LOCATIONS}"
        echo "    ${CAMO_BLOCK}"
        echo "}"
    } > "$conf"
    
    nginx -t && systemctl restart nginx && ok "Nginx Configured & Running!" || err "Nginx test failed."
}

# ---------------- Real IP / CDN Ranges ----------------
fetch_cloudflare_ranges() {
    v4=$(wget -qO- --timeout=10 https://www.cloudflare.com/ips-v4 2>/dev/null | tr '\n' ' ')
    v6=$(wget -qO- --timeout=10 https://www.cloudflare.com/ips-v6 2>/dev/null | tr '\n' ' ')
    printf '%s' "$v4" | grep -q '/' && CF_V4=$(printf '%s' "$v4" | tr -s ' ') || CF_V4="$CF_V4_DEFAULT"
    printf '%s' "$v6" | grep -q '/' && CF_V6=$(printf '%s' "$v6" | tr -s ' ') || CF_V6="$CF_V6_DEFAULT"
}
fetch_arvan_ranges() {
    v4=$(wget -qO- --timeout=12 -U "Mozilla/5.0" https://www.arvancloud.ir/en/ips.txt 2>/dev/null | tr -d '\r')
    v4=$(printf '%s\n' "$v4" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | sort -u | tr '\n' ' ')
    printf '%s' "$v4" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' && {
        ARVAN_V4=$(for x in $v4; do case "$x" in */*) echo "$x";; *) echo "$x/32";; esac; done | tr '\n' ' ')
    } || ARVAN_V4="$ARVAN_V4_DEFAULT"
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
        echo "# Real-IP from ${provider}"
        for c in $ranges4; do echo "set_real_ip_from $c;"; done
        for c in $ranges6; do echo "set_real_ip_from $c;"; done
        echo "real_ip_header ${hdr};"
        echo "real_ip_recursive on;"
    } > "$f"
    nginx -t >/dev/null 2>&1 && ok "${provider} real-IP enabled." || rm -f "$f"
}
write_cf_realip() { write_realip cloudflare; }

# ---------------- Whitelist GoldIP IP Resolver ----------------
resolve_domain_ips() {
    local domain="$1" ips=""
    if command -v dig >/dev/null 2>&1; then ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' '); fi
    if [ -z "$ips" ] && command -v host >/dev/null 2>&1; then ips=$(host -t A "$domain" 2>/dev/null | awk '/has address/{print $4}' | tr '\n' ' '); fi
    if [ -z "$ips" ] && command -v getent >/dev/null 2>&1; then ips=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | tr '\n' ' '); fi
    printf '%s' "$ips"
}

whitelist_goldip() {
    local ip hit=0
    local ips; ips=$(resolve_domain_ips "$GOLDIP_TRUSTED")
    for ip in $ips; do
        ufw allow from "$ip" >/dev/null 2>&1 && { ok "Whitelisted ${GOLDIP_TRUSTED} (${ip})"; hit=1; }
    done
    [ "$hit" -eq 1 ] || warn "Failed to whitelist ${GOLDIP_TRUSTED} (or domain not resolvable)."
}

# ---------------- Firewall (UFW) ----------------
setup_firewall() {
    command -v ufw >/dev/null 2>&1 || apt-get install -y ufw >/dev/null
    
    echo -e "${INFO}CDN Provider:${RESET}"
    echo -e "  ${M1}1)${RESET} Cloudflare  ${M2}2)${RESET} ArvanCloud  ${M3}3)${RESET} Both  ${M8}4)${RESET} Custom"
    local CDN_CHOICE; ask_choice CDN_CHOICE "Selection" "1|2|3|4"
    local RANGES="" RANGES6=""
    case "$CDN_CHOICE" in
        1) fetch_cloudflare_ranges; RANGES="$CF_V4"; RANGES6="$CF_V6" ;;
        2) fetch_arvan_ranges; RANGES="$ARVAN_V4"; RANGES6="$ARVAN_V6" ;;
        3) fetch_cloudflare_ranges; fetch_arvan_ranges; RANGES="$CF_V4 $ARVAN_V4"; RANGES6="$CF_V6 $ARVAN_V6" ;;
        4) ask RANGES "IPv4 CIDRs (space-separated)"; ask_optional RANGES6 "IPv6 CIDRs" ;;
    esac

    local SSH_PORT FW_HTTPS FW_HTTP TUN_PORT FOREIGN_IP=""
    ask_port SSH_PORT "SSH port" 22
    ask_port FW_HTTPS "HTTPS port exposed to CDN" 443
    ask_port FW_HTTP  "HTTP port exposed to CDN"  80
    ask_port_optional TUN_PORT "Tunnel port (e.g. 8443)"
    [ -n "$TUN_PORT" ] && ask_optional FOREIGN_IP "Tunnel allowed from IP" "(blank = any)"

    ufw --force reset >/dev/null; ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
    ufw allow "${SSH_PORT}/tcp" >/dev/null
    
    # Restore Whitelist GoldIP function call
    whitelist_goldip
    
    local XUI_PORTS="" xdb=""
    for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do [ -f "$c" ] && xdb="$c" && break; done
    if [ -n "$xdb" ]; then
        local pport sport iports
        pport=$(sqlite3 "$xdb" "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" 2>/dev/null)
        sport=$(sqlite3 "$xdb" "SELECT value FROM settings WHERE key='subPort' LIMIT 1;" 2>/dev/null)
        iports=$(sqlite3 "$xdb" "SELECT port FROM inbounds;" 2>/dev/null | tr '\n' ' ')
        XUI_PORTS=$(printf '%s\n' "${pport} ${sport} ${iports}" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u)
    fi

    # Allow TCP & UDP for X-ui (Hysteria fix)
    for p in $XUI_PORTS; do
        [ -z "$p" ] && continue
        ufw allow "${p}/tcp" >/dev/null 2>&1
        ufw allow "${p}/udp" >/dev/null 2>&1
    done

    local cidr
    for cidr in $RANGES; do
        ufw allow from "$cidr" to any port "$FW_HTTPS" proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port "$FW_HTTP"  proto tcp >/dev/null 2>&1
    done
    for cidr in $RANGES6; do
        ufw allow from "$cidr" to any port "$FW_HTTPS" proto tcp >/dev/null 2>&1
        ufw allow from "$cidr" to any port "$FW_HTTP"  proto tcp >/dev/null 2>&1
    done
    
    if [ -n "$TUN_PORT" ]; then
        [ -n "$FOREIGN_IP" ] && ufw allow from "$FOREIGN_IP" to any port "$TUN_PORT" proto tcp >/dev/null 2>&1 \
            || ufw allow "${TUN_PORT}/tcp" >/dev/null 2>&1
    fi

    ufw --force enable >/dev/null
    ok "Firewall Configured Successfully!"
    
    command -v nginx >/dev/null 2>&1 && {
        local RIP
        case "$CDN_CHOICE" in
            1) ask_optional RIP "Restore real IPs from Cloudflare in nginx?" "[y/N]"; is_yes "$RIP" && write_realip cloudflare ;;
            2) ask_optional RIP "Restore real IPs from ArvanCloud in nginx?" "[y/N]"; is_yes "$RIP" && write_realip arvan ;;
            3) ask_optional RIP "Restore real IPs? [c=CF / a=Arvan / blank=skip]"; case "$RIP" in c|C) write_realip cloudflare ;; a|A) write_realip arvan ;; esac ;;
        esac
    }
}
firewall_status() { command -v ufw >/dev/null 2>&1 && ufw status verbose || warn "ufw not installed."; }

# ---------------- Persistence & Watchdog ----------------
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

enable_persistence() {
    local mode="${1:-}"
    if command -v nginx >/dev/null 2>&1; then
        systemctl enable nginx >/dev/null 2>&1
        mkdir -p /etc/systemd/system/nginx.service.d
        local after="network-online.target"
        systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service' && after="network-online.target x-ui.service"
        cat > /etc/systemd/system/nginx.service.d/goldip.conf <<DEOF
[Unit]
After=${after}
Wants=network-online.target
[Service]
Restart=on-failure
RestartSec=3s
DEOF
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        systemctl enable x-ui >/dev/null 2>&1
        mkdir -p /etc/systemd/system/x-ui.service.d
        cat > /etc/systemd/system/x-ui.service.d/goldip.conf <<'XEOF'
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Restart=on-failure
RestartSec=3s
XEOF
    fi
    systemctl daemon-reload >/dev/null 2>&1
    ok "Persistence (auto-restart) applied."
    [ "$mode" = "silent" ] && return
    systemctl list-unit-files 2>/dev/null | grep -q '^goldip-watchdog\.timer' && ok "Watchdog active." \
        || { local WD; ask_optional WD "Install 1-min watchdog?" "[y/N]"; is_yes "$WD" && install_watchdog; }
}

# ---------------- Uninstall & Logs ----------------
full_uninstall() {
    echo -e "${ERR_BG} WARNING ${RESET} This will COMPLETELY remove Nginx and all configs!"
    local CONFIRM; ask_optional CONFIRM "Type YES to confirm"
    [ "$CONFIRM" = "YES" ] || { warn "Cancelled."; return; }
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    systemctl stop goldip-watchdog.timer 2>/dev/null || true
    systemctl disable goldip-watchdog.timer 2>/dev/null || true
    rm -f /etc/systemd/system/goldip-watchdog.* /usr/local/bin/goldip-watchdog.sh
    rm -rf /etc/systemd/system/nginx.service.d
    systemctl daemon-reload >/dev/null 2>&1
    apt-get purge -y nginx nginx-common nginx-full nginx-extras nginx-core 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    rm -rf /etc/nginx /var/log/nginx /var/www/goldip
    ok "Nginx fully uninstalled."
}

uninstall_domain() {
    local D; ask D "Domain config to remove"
    rm -f "${NGINX_CONF_DIR}/${D}.conf"
    command -v nginx >/dev/null 2>&1 && nginx -t 2>/dev/null && systemctl reload nginx && ok "Removed." || ok "Removed (nginx not running)."
}

colorize_access_line() {
    local line="$1" code
    code=$(printf '%s' "$line" | grep -oE '" [1-5][0-9][0-9] ' | head -n1 | tr -dc '0-9')
    case "$code" in
        5*) echo -e "${ERR_BG} ${code} ${RESET} $line" ;;
        4*) echo -e "${WARN_BG} ${code} ${RESET} $line" ;;
        2*|3*) echo -e "${OK_BG} ${code} ${RESET} $line" ;;
        *) echo -e "${M8}$line${RESET}" ;;
    esac
}

view_logs() {
    local logdir="/var/log/nginx"; [ -d "$logdir" ] || { err "No logs."; return; }
    local -a LOGS; local f i=0
    for f in "$logdir"/*.log; do [ -f "$f" ] || continue; i=$((i+1)); LOGS[$i]="$f"; done
    [ "$i" -gt 0 ] || { warn "No logs found."; return; }
    echo -e "${INFO}Logs:${RESET}"
    for n in $(seq 1 "$i"); do echo -e "  ${M8}${n})${RESET} ${LOGS[$n]}"; done
    local PICK; ask_number PICK "Select"
    { [ "$PICK" -ge 1 ] && [ "$PICK" -le "$i" ]; } || return
    tail -n 50 "${LOGS[$PICK]}" | while IFS= read -r line; do colorize_access_line "$line"; done
}

svc() {
    case "$1" in
        start)   systemctl start nginx   && ok "Nginx started"   || err "Start failed" ;;
        stop)    systemctl stop nginx    && ok "Nginx stopped"   || err "Stop failed" ;;
        restart) systemctl restart nginx && ok "Nginx restarted" || err "Restart failed" ;;
        reload)  nginx -t 2>/dev/null && systemctl reload nginx && ok "Nginx reloaded" || err "Reload failed" ;;
    esac
}
show_status() {
    systemctl is-active --quiet nginx && ok "Nginx is ACTIVE" || err "Nginx is INACTIVE"
    systemctl is-active --quiet x-ui && ok "x-ui is ACTIVE" || err "x-ui is INACTIVE"
    nginx -t 2>&1
}

# ---------------- Main Menu ----------------
do_install() { install_nginx; ensure_sqlite3; gather_inputs; write_config || return 1; enable_persistence silent; }

menu() {
    while true; do
        clear; echo -e "${TITLE}"; header; echo -e "${RESET}"
        echo -e "  ${M1}1)  Install / Config website"
        echo -e "  ${M2}2)  Start Nginx"
        echo -e "  ${M3}3)  Stop Nginx"
        echo -e "  ${M4}4)  Restart Nginx"
        echo -e "  ${M5}5)  Reload Nginx"
        echo -e "  ${M7}6)  Status"
        echo -e "  ${M8}7)  View logs"
        echo -e "  ${M9}8)  Remove domain config"
        echo -e "  ${M11}9)  Setup firewall"
        echo -e "  ${M10}10) Firewall status"
        echo -e "  ${M12}11) Fix auto-start (persistence)"
        echo -e "  ${M6}12) FULL Nginx uninstall + cleanup"
        echo -e "  ${M6}0)  Exit"
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

require_root; menu
