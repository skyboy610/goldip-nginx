#xh/bin/bash
# ============================================================
#  GoldIP Nginx Camouflage Installer & Manager  v4.5 (Fixed)
# ============================================================
set -uo pipefail

RESET='\033[0m'

# ---------------- Color Palette (standard ANSI, colors 1-7 + gray) ----------------
C1='\033[1;31m'   # 1 red
C2='\033[1;32m'   # 2 green
C3='\033[1;33m'   # 3 yellow
C4='\033[1;34m'   # 4 blue
C5='\033[1;35m'   # 5 magenta
C6='\033[1;36m'   # 6 cyan
C7='\033[1;37m'   # 7 white
C8='\033[0;90m'   # 8 gray

TITLE="$C6"; INFO="$C4"

C_OK="$C2"
C_ERR="$C1"

OK_BG='\033[42m\033[30m'          # green bg,  black text -> success
WARN_BG='\033[48;5;208m\033[30m'  # orange bg, black text -> warning
ERR_BG='\033[41m\033[97m'         # red bg,    white text -> error

SKIP_BG='\033[1;30;43m'   # yellow bg, black text -> skipped (non-CDN) inbound
FIX_BG='\033[1;30;46m'    # cyan bg,   black text -> Host-header fix applied
CDN_BG="$C6"              # cyan text (no bg) -> CDN-routed inbound label

PALETTE=(C1 C2 C3 C4 C5 C6 C7 C8)
__cidx=0
CURCOLOR=""
nextcolor() {
    local name="${PALETTE[$__cidx]}"
    __cidx=$(( (__cidx + 1) % ${#PALETTE[@]} ))
    CURCOLOR="${!name}"
}

ok()   { echo -e "${OK_BG} OK: $1 ${RESET}"; }
warn() { echo -e "${WARN_BG} WARN: $1 ${RESET}"; }
err()  { echo -e "${ERR_BG} ERROR: $1 ${RESET}"; }
fix()  { echo -e "${OK_BG} FIXED: $1 ${RESET}"; }

NGINX_CONF_DIR="/etc/nginx/conf.d"
CAMO_ROOT="/var/www/goldip"
GOLDIP_TRUSTED="goldip.net"

CF_V4_DEFAULT="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF_V6_DEFAULT="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
ARVAN_V4_DEFAULT="178.131.120.48/28 185.143.232.0/22 185.215.232.0/22 188.229.116.16/30 2.144.3.128/28 37.32.16.0/27 37.32.17.0/27 37.32.18.0/27 37.32.19.0/27 78.157.36.112/28 94.101.182.0/27 94.101.183.0/28"
ARVAN_V6_DEFAULT=""
CF_V4=""; CF_V6=""; ARVAN_V4=""; ARVAN_V6=""

# ---------------- Spinner ----------------
SPINNER_PID=""
start_spinner() {
    local msg="${1:-Working}"
    ( local i=0
      local frames='|/-\'
      while :; do
          i=$(( (i+1) % 4 ))
          printf "\r${INFO}%s %s${RESET}" "$msg" "${frames:$i:1}"
          sleep 0.15
      done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}
stop_spinner() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" >/dev/null 2>&1
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
        printf "\r%*s\r" 60 ""
    fi
}
run_with_spinner() {
    local msg="$1"; shift
    start_spinner "$msg"
    "$@"
    local rc=$?
    stop_spinner
    return $rc
}

# ---------------- Input helpers ----------------
ask() {
    local __var="$1" __q="$2" __hint="${3:-}" __ans __c
    while true; do
        nextcolor; __c="$CURCOLOR"
        [ -n "$__hint" ] && echo -e "${__c}${__q} ${__hint}:${RESET}" || echo -e "${__c}${__q}:${RESET}"
        read -r __ans
        [ -n "$__ans" ] && { printf -v "$__var" '%s' "$__ans"; return 0; }
        warn "Empty."
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
        case "$__ans" in ''|*[!0-9]*) warn "Number only."; continue ;; esac
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
        { [ "$__ans" -ge 1 ] && [ "$__ans" -le 65535 ]; } || { warn "Out of range."; continue; }
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}
ask_port_optional() {
    local __var="$1" __q="$2" __ans __c
    while true; do
        nextcolor; __c="$CURCOLOR"
        echo -e "${__c}${__q} (blank=skip):${RESET}"
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
        [ -z "$__ans" ] && { warn "Empty."; continue; }
        [ -f "$__ans" ] || { err "Not found: $__ans"; continue; }
        printf -v "$__var" '%s' "$__ans"; return 0
    done
}
ask_choice() {
    local __var="$1" __q="$2"; shift 2
    local -a __labels=("$@")
    local __valid="" __ans __c __o __num __text
    while true; do
        echo -e "${INFO}${__q}${RESET}"
        __valid=""
        for __o in "${__labels[@]}"; do
            __num="${__o%%:*}"; __text="${__o#*:}"
            nextcolor
            echo -e "  ${CURCOLOR}${__num}) ${__text}${RESET}"
            [ -z "$__valid" ] && __valid="$__num" || __valid="${__valid}|${__num}"
        done
        read -r __ans
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
 ██████╗  ██████╗ ██╗     ██████╗ ██╗██████╗
██╔════╝ ██╔═══██╗██║     ██╔══██╗██║██╔══██╗
██║  ███╗██║   ██║██║     ██║  ██║██║██████╔╝
██║   ██║██║   ██║██║     ██║  ██║██║██╔═══╝
╚██████╔╝╚██████╔╝███████╗██████╔╝██║██║
 ╚═════╝  ╚═════╝ ╚══════╝╚═════╝ ╚═╝╚═╝
       N G I N X   C A M O U F L A G E   v4.5
EOF
}

is_installed() {
    [ -f "${NGINX_CONF_DIR}/00-goldip-catchall.conf" ]
}

install_status_banner() {
    if is_installed; then
        echo -e "${OK_BG}                        INSTALLED                        ${RESET}"
    else
        echo -e "${ERR_BG}                      NOT INSTALLED                      ${RESET}"
    fi
}

draw_header() {
    clear
    echo -e "${TITLE}"
    header
    echo -e "${RESET}"
    install_status_banner
    echo ""
}

require_root() { [ "$(id -u)" -eq 0 ] || { err "Run as root."; exit 1; }; }

ensure_sqlite3() {
    command -v sqlite3 >/dev/null 2>&1 && return 0
    run_with_spinner "Installing sqlite3" apt-get install -y sqlite3 >/dev/null 2>&1
}

# ---------------- install nginx ----------------
install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        if nginx -V 2>&1 | grep -q 'http_sub_module'; then
            ok "Nginx already installed (http_sub_module present)."
            return 0
        fi
        warn "Reinstalling nginx as nginx-extras (missing http_sub_module)..."
    fi

    run_with_spinner "Updating package lists" apt-get update -y >/dev/null 2>&1
    run_with_spinner "Removing old nginx packages" apt-get remove -y nginx nginx-core nginx-light nginx-full nginx-common >/dev/null 2>&1
    run_with_spinner "Cleaning up" apt-get autoremove -y >/dev/null 2>&1

    start_spinner "Installing nginx-extras (this can take a minute)"
    apt-get install -y nginx-extras > /tmp/goldip_nginx_install.log 2>&1
    local install_rc=$?
    stop_spinner

    if [ "$install_rc" -eq 0 ]; then
        ok "Nginx (extras build) installed."
    else
        err "nginx-extras install failed. Last 20 lines of apt log:"
        tail -n 20 /tmp/goldip_nginx_install.log
        exit 1
    fi

    nginx -V 2>&1 | grep -q 'http_sub_module' || {
        err "http_sub_module still missing. Camouflage sub_filter cannot work. Aborting."
        exit 1
    }
    nginx -V 2>&1 | grep -q 'http_v2_module' || warn "http_v2_module not detected -- verify manually if XHTTP misbehaves."
}

# ---------------- Location Builder ----------------
make_location() {
    local t="$1" p="$2" port="$3" hostheader="$4"
    [ "${p:0:1}" != "/" ] && p="/$p"
    if [ "$t" = "xhttp" ]; then
        printf '    location ^~ %s {\n' "$p"
        printf '        proxy_pass http://127.0.0.1:%s;\n' "$port"
        printf '        proxy_http_version 1.1;\n'
        printf '        proxy_set_header X-Real-IP $remote_addr;\n'
        printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
        printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
        printf '        proxy_set_header Connection "keep-alive";\n'
        printf '        client_max_body_size 0;\n'
        printf '        client_body_timeout 1h;\n'
        printf '        proxy_buffering off;\n'
        printf '        proxy_request_buffering off;\n'
        printf '        proxy_read_timeout 1h;\n'
        printf '        proxy_send_timeout 1h;\n'
        printf '    }\n'
    else
        printf '    location ^~ %s {\n' "$p"
        printf '        proxy_pass http://127.0.0.1:%s;\n' "$port"
        printf '        proxy_http_version 1.1;\n'
        printf '        proxy_set_header Upgrade $http_upgrade;\n'
        printf '        proxy_set_header Connection "upgrade";\n'
        printf '        proxy_set_header Host %s;\n' "$hostheader"
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
        xhttp|splithttp) printf '["http/1.1","h2"]' ;;
        *) printf '["http/1.1"]' ;;
    esac
}

hosts_table_exists() {
    python3 - "$1" <<'PYEOF'
import sqlite3, sys
try:
    con = sqlite3.connect(sys.argv[1])
    cur = con.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='hosts'")
    print("YES" if cur.fetchone() else "NO")
    con.close()
except Exception:
    print("NO")
PYEOF
}

insert_host_py() {
    python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" <<'PYEOF'
import sqlite3, sys, time
db_path, inbound_id, remark, cdn_host, port, sni, path, alpn_json = sys.argv[1:9]
now_ms = int(time.time() * 1000)
try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("""
        INSERT INTO hosts (
            inbound_id, sort_order, remark, server_description, is_disabled, is_hidden,
            address, port, security, sni, host_header, path, alpn, fingerprint, override_sni_from_address,
            keep_sni_blank, allow_insecure, created_at, updated_at
        ) VALUES (?, 0, ?, '', 0, 0, ?, ?, 'tls', ?, ?, ?, ?, 'chrome', 1, 0, 0, ?, ?)
    """, (int(inbound_id), remark, cdn_host, int(port), sni, cdn_host, path, alpn_json, now_ms, now_ms))
    con.commit(); con.close(); print("OK"); sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)
PYEOF
}

strip_tls_py() {
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import sqlite3, json, sys
try:
    con = sqlite3.connect(sys.argv[1]); cur = con.cursor()
    inb_id = int(sys.argv[2]); net = sys.argv[3]; cdn_host = sys.argv[4]
    cur.execute("SELECT stream_settings FROM inbounds WHERE id=?", (inb_id,))
    row = cur.fetchone()
    if not row or not row[0]:
        print("ERROR: inbound not found or empty stream_settings", file=sys.stderr)
        sys.exit(1)

    ss = json.loads(row[0])
    ss["security"] = "none"
    for k in ("tlsSettings", "realitySettings", "externalProxy", "externalProxySettings"):
        ss.pop(k, None)

    if net == "ws":
        ws = ss.setdefault("wsSettings", {})
        headers = ws.setdefault("headers", {})
        headers.pop("Host", None)
        ws["host"] = ""
    elif net == "httpupgrade":
        hu = ss.setdefault("httpupgradeSettings", {})
        hu["host"] = ""
    elif net in ("xhttp", "splithttp"):
        s_key = net + "Settings"
        xs = ss.setdefault(s_key, {})
        xs["host"] = ""
        xs.pop("mode", None)
        xs.pop("extra", None)
        xs["xPaddingBytes"] = "100-1000"
    else:
        print(f"ERROR: unsupported network type '{net}'", file=sys.stderr)
        sys.exit(1)

    cur.execute("UPDATE inbounds SET stream_settings=? WHERE id=?", (json.dumps(ss), inb_id))
    con.commit()
    con.close()
    print("OK"); sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)
PYEOF
}

# ---------------- SSL Discovery ----------------
find_certificate_for_domain() {
    local domain; domain=$(strip_port "${1:-}")
    [ -n "$domain" ] || return 1

    if [ -f "/root/goldip/cert.pem" ] && [ -f "/root/goldip/key.pem" ]; then
        printf '%s|%s' "/root/goldip/cert.pem" "/root/goldip/key.pem"; return 0
    fi

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

# ---------------- "Connection is not private" diagnostics ----------------
check_cert_browser_trust() {
    local cert="$1" domain="$2"
    local issuer is_origin_ca=0 resolved_ip

    issuer=$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null)

    if printf '%s' "$issuer" | grep -qiE 'Cloudflare'; then
        is_origin_ca=1
    fi
    if openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -q '1.3.6.1.4.1.44947'; then
        is_origin_ca=1
    fi

    if [ "$is_origin_ca" -eq 1 ]; then
        warn "This is a Cloudflare ORIGIN certificate (issuer: ${issuer#issuer=})."
        warn "Real clients will show 'not private' unless the domain is Proxied"
        warn "(orange cloud) with SSL mode Full/Full (strict)."
        echo ""

        resolved_ip=$(resolve_domain_ips "$domain")
        if [ -n "$resolved_ip" ]; then
            local sample_ip; sample_ip=$(printf '%s' "$resolved_ip" | awk '{print $1}')
            if printf '%s' "$sample_ip" | grep -qE '^(173\.245\.|103\.21\.|103\.22\.|103\.31\.|141\.101\.|108\.162\.|190\.93\.|188\.114\.|197\.234\.|198\.41\.|162\.158\.|104\.16\.|104\.24\.|172\.6[4-9]\.|172\.7[01]\.|131\.0\.72\.)'; then
                ok "DNS: ${domain} -> ${sample_ip} (Cloudflare, Proxied). Good."
            else
                err "DNS: ${domain} -> ${sample_ip} -- NOT a Cloudflare IP (grey cloud)."
                err "Fix: Cloudflare dashboard -> DNS -> orange-cloud ${domain}."
            fi
        else
            warn "Could not resolve ${domain} to verify proxy status."
        fi
        echo ""
        local CONT; ask_optional CONT "Continue anyway?" "[y/N]"
        is_yes "$CONT" || { err "Aborted. Fix the Cloudflare proxy/cert and re-run."; exit 1; }
    else
        ok "Certificate issuer looks fine for direct trust."
    fi
}

check_cert_covers_domain() {
    local cert="$1" domain="$2" label="$3"
    local san cn

    san=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | tr -d ' ' | tr ',' '\n' | grep -oE 'DNS:[^,]+' | sed 's/^DNS://')
    cn=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | grep -oE 'CN\s*=\s*[^,/]+' | sed -E 's/CN\s*=\s*//')

    local covered=0
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        if [ "$name" = "$domain" ]; then covered=1; break; fi
        case "$name" in
            \*.*)
                local suffix="${name#\*.}"
                case "$domain" in *".${suffix}") covered=1; break ;; esac
                ;;
        esac
    done <<< "$san"

    if [ "$covered" -eq 0 ] && [ "$cn" = "$domain" ]; then covered=1; fi

    if [ "$covered" -eq 1 ]; then
        ok "Certificate covers ${label} (${domain})."
        return 0
    else
        err "Certificate does NOT cover ${label} (${domain})."
        err "SAN list: $(printf '%s' "$san" | tr '\n' ' ')"
        err "CN: ${cn}"
        return 1
    fi
}

# ---------------- Auto Build Locations ----------------
CDN_ROUTED_SUMMARY=""
NONCDN_SUMMARY=""
HOSTFIX_SUMMARY=""
FAILED_SUMMARY=""
HOSTS_TABLE_PRESENT=1

auto_build_locations() {
    local db=""; for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do [ -f "$c" ] && db="$c" && break; done
    [ -z "$db" ] && return 1
    ok "Reading inbounds from: $db"

    local idx=0 id port ss net path rawpath remark rawremark
    local -a IN_ID IN_PORT IN_NET IN_PATH IN_SS IN_REMARK
    while IFS='|' read -r id port ss remark; do
        [ -n "$port" ] || continue
        net=$(printf '%s' "$ss" | grep -oE '"network"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        rawpath=$(printf '%s' "$ss" | grep -oE '"path"[ ]*:[ ]*"[^"]*"' | head -n1 | sed -E 's/.*:[ ]*"([^"]*)"/\1/')
        path="${rawpath%%\?*}"
        idx=$((idx+1))
        IN_ID[$idx]="$id"; IN_PORT[$idx]="$port"; IN_NET[$idx]="${net:-unknown}"; IN_PATH[$idx]="$path"
        IN_SS[$idx]="$ss"; IN_REMARK[$idx]="${remark:-inbound-$id}"
    done < <(sqlite3 -separator '|' "$db" "SELECT id, port, replace(replace(stream_settings, char(10), ' '), char(13), ' '), remark FROM inbounds;" 2>/dev/null)

    LOCATIONS=""; USED_PORTS=$(ss -ltn 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': ' | tr '\n' ' ')
    TAKEN_PORTS=""; local added=0
    local -a OP_IDS OP_FPORTS OP_NETS OP_PATHS OP_ALPNS OP_REMARKS
    local op_count=0 ltype fport

    for n in $(seq 1 "$idx"); do
        net="${IN_NET[$n]}"; port="${IN_PORT[$n]}"; path="${IN_PATH[$n]}"; id="${IN_ID[$n]}"; remark="${IN_REMARK[$n]}"

        case "$net" in
            ws|httpupgrade) ltype="upgrade" ;;
            xhttp|splithttp) ltype="xhttp" ;;
            *)
                echo -e "${SKIP_BG} SKIP ${RESET} ${net} \"${remark}\" (port ${port}) -- stays direct, not behind CDN."
                NONCDN_SUMMARY="${NONCDN_SUMMARY}"$'\n'"  - [${net}] \"${remark}\" port ${port} -> direct via ${PANEL_DOMAIN:-<server IP>}"
                continue ;;
        esac

        if [ -z "$path" ] || [ "$path" = "/" ]; then
            warn "Inbound \"${remark}\" (${net}, port ${port}) has no distinct path"
            warn "(path='${path:-<empty>}'). A CDN inbound behind nginx MUST have a unique"
            warn "path like /mypath so nginx can route it; otherwise it collides with the"
            warn "camouflage site and returns 404. Set a path on this inbound and re-run."
            continue
        fi
        fport="$port"
        if [ "$port" = "$HTTPS_PORT" ] || [ "$port" = "$HTTP_PORT" ]; then fport=$(free_port); fi
        TAKEN_PORTS="${TAKEN_PORTS} ${fport}"

        op_count=$((op_count+1))
        OP_IDS[$op_count]="$id"; OP_FPORTS[$op_count]="$fport"; OP_NETS[$op_count]="$net"
        OP_PATHS[$op_count]="$path"; OP_ALPNS[$op_count]=$(alpn_for_net "$net"); OP_REMARKS[$op_count]="$remark"

        LOCATIONS="${LOCATIONS}"$'\n'"$(make_location "$ltype" "$path" "$fport" "$PRIMARY")"
        echo -e "${CDN_BG} CDN ${RESET} ${net} \"${remark}\" ${path} -> 127.0.0.1:${fport}"
        CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [${net}] \"${remark}\" ${path} -> via ${PRIMARY}"
        added=$((added+1))
    done

    [ "$added" -eq 0 ] && { warn "No CDN-compatible inbounds found."; return 1; }

    cp "$db" "${db}.bak.$(date +%s)" 2>/dev/null
    ok "Backed up x-ui.db before writing changes."

    HOSTS_TABLE_PRESENT=1
    if [ "$(hosts_table_exists "$db")" != "YES" ]; then
        HOSTS_TABLE_PRESENT=0
        warn "This x-ui/3x-ui panel has no 'hosts' (Managed Hosts) table -- skipping"
        warn "subscription-link cosmetic step (older panel version). Routing itself"
        warn "is unaffected: it does not depend on this table."
    fi

    FAILED_SUMMARY=""
    HOSTFIX_SUMMARY=""
    local applied_count=0

    for m in $(seq 1 "$op_count"); do
        mid="${OP_IDS[$m]}"; mfport="${OP_FPORTS[$m]}"; mnet="${OP_NETS[$m]}"; malpn="${OP_ALPNS[$m]}"; mremark="${OP_REMARKS[$m]}"; mpath="${OP_PATHS[$m]}"
        local step_ok=1

        if ! sqlite3 "$db" "UPDATE inbounds SET listen='127.0.0.1', port=${mfport} WHERE id=${mid};" 2>/tmp/goldip_sqlerr; then
            err "Failed to move inbound #${mid} (\"${mremark}\") to 127.0.0.1:${mfport}: $(cat /tmp/goldip_sqlerr)"
            step_ok=0
        fi

        if [ "$step_ok" -eq 1 ]; then
            local strip_out
            strip_out=$(strip_tls_py "$db" "$mid" "$mnet" "$PRIMARY" 2>&1)
            if [ "$strip_out" != "OK" ]; then
                err "Failed to fix transport Host/mode for inbound #${mid} (\"${mremark}\"): ${strip_out}"
                step_ok=0
            fi
        fi

        if [ "$step_ok" -eq 1 ] && [ "$HOSTS_TABLE_PRESENT" -eq 1 ]; then
            sqlite3 "$db" "DELETE FROM hosts WHERE inbound_id=${mid};" 2>/dev/null
            local host_out
            host_out=$(insert_host_py "$db" "$mid" "$mremark" "$PRIMARY" "$HTTPS_PORT" "$PRIMARY" "$mpath" "$malpn" 2>&1)
            if [ "$host_out" != "OK" ]; then
                warn "Cosmetic subscription-link update failed for #${mid} (\"${mremark}\") -- routing is unaffected: ${host_out}"
            fi
        fi

        if [ "$step_ok" -eq 1 ]; then
            applied_count=$((applied_count+1))
            HOSTFIX_SUMMARY="${HOSTFIX_SUMMARY}"$'\n'"  - #${mid} \"${mremark}\" [${mnet}] -> Host/mode fixed, listening 127.0.0.1:${mfport}"
        else
            FAILED_SUMMARY="${FAILED_SUMMARY}"$'\n'"  - #${mid} \"${mremark}\" [${mnet}] -> DB WRITE FAILED, nginx location will NOT work for this inbound"
        fi
    done

    if [ "$applied_count" -eq 0 ]; then
        err "ALL database writes failed. No CDN inbound will work until this is fixed."
        return 1
    fi
    if [ -n "$FAILED_SUMMARY" ]; then
        err "Some inbounds failed to update (see above) -- they will NOT work:"
        echo -e "${FAILED_SUMMARY}"
    fi

    ok "Database updated for ${applied_count}/${op_count} inbound(s). Restarting x-ui..."
    systemctl restart x-ui

    echo ""
    echo -e "${INFO}--- Verifying live binding ---${RESET}"
    print_verify_table "$db"
    return 0
}

print_verify_table() {
    local db="$1"
    printf "%-4s %-22s %-10s %-10s %-6s %-22s %-22s %-9s\n" "ID" "Remark" "Net" "Listen" "Port" "TransportHost" "hosts.address" "Verdict"
    while IFS='|' read -r iid remark net listen port thost haddr hheader verdict; do
        [ -z "$iid" ] && continue
        if [ "$verdict" = "MATCH" ]; then
            echo -e "${C_OK}$(printf "%-4s %-22s %-10s %-10s %-6s %-22s %-22s %-9s" "$iid" "${remark:0:22}" "$net" "$listen" "$port" "${thost:-<empty>}" "${haddr:-<none>}" "$verdict")${RESET}"
        else
            echo -e "${C_ERR}$(printf "%-4s %-22s %-10s %-10s %-6s %-22s %-22s %-9s" "$iid" "${remark:0:22}" "$net" "$listen" "$port" "${thost:-<empty>}" "${haddr:-<none>}" "$verdict")${RESET}"
        fi
    done < <(verify_cdn_binding_py "$db" "$PRIMARY")
}

verify_cdn_binding_py() {
    python3 - "$1" "$2" <<'PYEOF'
import sqlite3, json, sys
db_path, cdn_host = sys.argv[1:3]
con = sqlite3.connect(db_path); cur = con.cursor()
cur.execute("SELECT id, remark, listen, port, stream_settings FROM inbounds ORDER BY id;")
rows = cur.fetchall()

hosts_exists = False
try:
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='hosts'")
    hosts_exists = cur.fetchone() is not None
except Exception:
    pass

for iid, remark, listen, port, ss_raw in rows:
    if not ss_raw:
        continue
    try:
        ss = json.loads(ss_raw)
    except Exception:
        continue
    net = ss.get("network", "")
    if net not in ("ws", "xhttp", "splithttp", "httpupgrade"):
        continue
    transport_host = ""
    if net == "ws":
        transport_host = (ss.get("wsSettings") or {}).get("headers", {}).get("Host", "")
    elif net in ("xhttp", "splithttp"):
        transport_host = (ss.get(net + "Settings") or {}).get("host", "")
    elif net == "httpupgrade":
        transport_host = (ss.get("httpupgradeSettings") or {}).get("host", "")

    hosts_address = "(no hosts table)"
    hosts_hostheader = "(no hosts table)"
    if hosts_exists:
        cur.execute("SELECT address, host_header FROM hosts WHERE inbound_id=? ORDER BY id DESC LIMIT 1;", (iid,))
        hrow = cur.fetchone()
        hosts_address = hrow[0] if hrow else "(none)"
        hosts_hostheader = hrow[1] if hrow else "(none)"

    listen_ok = (listen == "127.0.0.1")
    host_ok = (transport_host == cdn_host or transport_host == "")
    match = "MATCH" if (listen_ok and host_ok) else "MISMATCH"
    print(f"{iid}|{remark}|{net}|{listen}|{port}|{transport_host}|{hosts_address}|{hosts_hostheader}|{match}")
con.close()
PYEOF
}

verify_cdn_binding_menu() {
    local db=""; for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do [ -f "$c" ] && db="$c" && break; done
    [ -z "$db" ] && { err "x-ui database not found."; return 1; }
    local CDNIN; ask CDNIN "CDN Domain"
    CDNIN=$(strip_scheme "$CDNIN")
    echo -e "${INFO}--- Live binding check for ${CDNIN} ---${RESET}"
    print_verify_table "$db"
    echo ""
    warn "MISMATCH means either the listen address isn't 127.0.0.1 or the real"
    warn "transport Host header doesn't equal the CDN domain. Run Install again"
    warn "(Auto discovery) to force-correct any MISMATCH rows."
}

# ============================================================
# Diagnostic for "CDN inbounds stop working after some days".
# ============================================================
diagnose_delayed_disconnect() {
    echo -e "${INFO}=== 1. Disk space ===${RESET}"
    local disk_line disk_pct
    disk_line=$(df -h / 2>/dev/null | tail -n1)
    disk_pct=$(printf '%s' "$disk_line" | awk '{print $5}' | tr -d '%')
    echo "  ${disk_line}"
    if [ -n "$disk_pct" ] && [ "$disk_pct" -ge 90 ]; then
        err "Root filesystem is ${disk_pct}% full. This alone can cause nginx to fail unpredictably."
    elif [ -n "$disk_pct" ] && [ "$disk_pct" -ge 75 ]; then
        warn "Root filesystem is ${disk_pct}% full. Worth monitoring."
    else
        ok "Disk usage looks fine (${disk_pct:-unknown}%)."
    fi

    echo ""
    echo -e "${INFO}=== 2. nginx log file sizes ===${RESET}"
    if [ -d /var/log/nginx ]; then
        local big_logs
        big_logs=$(find /var/log/nginx -maxdepth 1 -name '*.log' -size +200M 2>/dev/null)
        if [ -n "$big_logs" ]; then
            err "Oversized (>200MB) nginx logs found:"
            printf '%s\n' "$big_logs" | while read -r f; do echo "    $(du -h "$f" 2>/dev/null)"; done
        else
            ok "No oversized nginx log files."
        fi
    else
        warn "/var/log/nginx does not exist."
    fi

    echo ""
    echo -e "${INFO}=== 3. nginx crash/restart history (14 days) ===${RESET}"
    if command -v journalctl >/dev/null 2>&1; then
        local restarts
        restarts=$(journalctl -u nginx --since "-14 days" 2>/dev/null | grep -ciE 'fail|core dump|killed|out of memory|segfault')
        if [ "$restarts" -gt 0 ]; then
            err "Found ${restarts} nginx failure lines in the last 14 days:"
            err "  journalctl -u nginx --since '-14 days' | grep -iE 'fail|killed|memory'"
        else
            ok "No nginx crash/OOM lines found."
        fi
    else
        warn "journalctl not available."
    fi

    echo ""
    echo -e "${INFO}=== 4. x-ui client expiry / traffic quota ===${RESET}"
    local db=""; for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do [ -f "$c" ] && db="$c" && break; done
    if [ -n "$db" ]; then
        local now_ms; now_ms=$(($(date +%s) * 1000))
        local expired_count quota_exceeded
        expired_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM client_traffics WHERE enable=1 AND expiry_time > 0 AND expiry_time < ${now_ms};" 2>/dev/null)
        quota_exceeded=$(sqlite3 "$db" "SELECT COUNT(*) FROM client_traffics WHERE enable=1 AND total > 0 AND (up + down) >= total;" 2>/dev/null)
        if [ -n "$expired_count" ] && [ "$expired_count" -gt 0 ]; then
            warn "${expired_count} enabled client(s) already past expiry_time -- looks like a routing failure but isn't."
        fi
        if [ -n "$quota_exceeded" ] && [ "$quota_exceeded" -gt 0 ]; then
            warn "${quota_exceeded} enabled client(s) exhausted their traffic quota."
        fi
        if [ "${expired_count:-0}" -eq 0 ] && [ "${quota_exceeded:-0}" -eq 0 ]; then
            ok "No expired or quota-exhausted clients."
        fi
    else
        warn "x-ui database not found."
    fi

    echo ""
    echo -e "${INFO}=== 5. Live listen-state cross-check ===${RESET}"
    if [ -n "$db" ]; then
        local listening_ports; listening_ports=$(ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -oE '[0-9]+$' | sort -u)
        while IFS='|' read -r iid remark listen port net; do
            [ -z "$iid" ] && continue
            case "$net" in ws|httpupgrade|xhttp|splithttp) : ;; *) continue ;; esac
            if printf '%s\n' "$listening_ports" | grep -qx "$port"; then
                echo -e "${C_OK}  [OK] #${iid} (${remark}) port ${port} is listening.${RESET}"
            else
                echo -e "${C_ERR}  [DOWN] #${iid} (${remark}) port ${port} is NOT listening. Restart x-ui and check its log.${RESET}"
            fi
        done < <(sqlite3 -separator '|' "$db" "SELECT id, remark, listen, port, json_extract(stream_settings,'\$.network') FROM inbounds;" 2>/dev/null)
    fi

    echo ""
    echo -e "${INFO}=== 6. UFW status ===${RESET}"
    if command -v ufw >/dev/null 2>&1; then
        local ufw_state; ufw_state=$(ufw status 2>/dev/null | head -n1)
        echo "  ${ufw_state}"
        if printf '%s' "$ufw_state" | grep -qi inactive; then
            warn "UFW is INACTIVE."
        else
            ok "UFW is active. Re-run Setup Firewall after adding/changing inbounds."
        fi
    else
        warn "ufw not installed."
    fi

    echo ""
    echo -e "${INFO}Summary: red lines above are verified facts on this system, not speculation.${RESET}"
}

_build_camo_block() {
    local js_file="/tmp/goldip_js_$$.js"
    cat > "$js_file" <<JSEOF
<script>(function(){var H="PROXY_HOST_PH",S="PROXY_SCHEME_PH";var r1=new RegExp(S+"://"+H.replace(/\./g,"\\."),\"g\");var r2=new RegExp("//"+H.replace(/\./g,"\\."),\"g\");function c(u){return typeof u==="string"?u.replace(r1,"").replace(r2,""):u;}var oF=window.fetch;window.fetch=function(u,o){return oF.call(this,c(u),o);};var oX=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){return oX.apply(this,[m,c(u)].concat(Array.prototype.slice.call(arguments,2)));};var oP=history.pushState,oR=history.replaceState;history.pushState=function(s,t,u){return oP.call(this,s,t,c(u));};history.replaceState=function(s,t,u){return oR.call(this,s,t,c(u));};try{var dl=Object.getOwnPropertyDescriptor(window.location,"href");if(dl&&dl.set){Object.defineProperty(window.location,"href",{set:function(v){window.history.replaceState(null,"",c(v));},get:dl.get,configurable:true});}}catch(e){}document.addEventListener("click",function(e){var a=e.target.closest("a");if(!a)return;var h=a.getAttribute("href")||\"\";if(r1.test(h)||r2.test(h)){e.preventDefault();window.history.pushState(null,"",c(h));}},true);})();</script>
JSEOF
    local js_inline
    js_inline=$(sed "s|PROXY_HOST_PH|${PROXY_HOST}|g; s|PROXY_SCHEME_PH|${PROXY_SCHEME}|g" "$js_file" | tr -d '\n')
    rm -f "$js_file"

    CAMO_SUBFILTER_DIRECTIVES="        gzip off;
        sub_filter_once off;
        sub_filter_types text/html text/css text/xml text/plain text/javascript application/javascript application/json;
        sub_filter '${PROXY_SCHEME}://${PROXY_HOST}' '';
        sub_filter 'https://${PROXY_HOST}' '';
        sub_filter 'http://${PROXY_HOST}' '';
        sub_filter '//${PROXY_HOST}' '';
        sub_filter '</head>' '${js_inline}</head>';"

    CAMO_PROXY_DIRECTIVES="        proxy_pass ${PROXY_SCHEME}://${PROXY_HOST}${PROXY_BASEPATH};
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
        proxy_http_version 1.1;
        proxy_set_header Connection '';
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        proxy_buffers 32 16k;
        proxy_buffer_size 32k;"

    CAMO_BLOCK="    location / {
${CAMO_PROXY_DIRECTIVES}
${CAMO_SUBFILTER_DIRECTIVES}
    }"
}

# ---------------- auto-locate index.html ----------------
find_index_html_auto() {
    local -a common_paths=(
        "/root/goldip/index.html"
        "/root/index.html"
        "/var/www/html/index.html"
        "$(pwd)/index.html"
    )
    local p
    for p in "${common_paths[@]}"; do
        [ -f "$p" ] && { printf '%s' "$p"; return 0; }
    done

    local found
    found=$(find /root /home /var/www /opt 2>/dev/null -maxdepth 4 -iname "index.html" \
        -not -path "*/node_modules/*" \
        -not -path "*/.git/*" \
        -not -path "${CAMO_ROOT}/*" \
        2>/dev/null | head -n1)
    [ -n "$found" ] && { printf '%s' "$found"; return 0; }
    return 1
}

# ---------------- Setup Flow ----------------
gather_inputs() {
    CDN_ROUTED_SUMMARY=""; NONCDN_SUMMARY=""; HOSTFIX_SUMMARY=""; FAILED_SUMMARY=""

    echo -e "${INFO}=== Panel ===${RESET}"
    ask RAW_PANEL "Panel Domain"
    PANEL_DOMAIN=$(strip_scheme "$RAW_PANEL"); PANEL_DOMAIN=$(strip_port "$PANEL_DOMAIN")
    ask_port PANEL_PORT "Panel Port" 2053

    echo -e "${INFO}=== CDN ===${RESET}"
    ask RAW_CDN "CDN Domain"
    CDN_DOMAIN=$(strip_scheme "$RAW_CDN"); PRIMARY="$CDN_DOMAIN"
    ask_port HTTPS_PORT "HTTPS Port" 443
    ask_port HTTP_PORT  "HTTP Port"  80

    if [ "$PANEL_PORT" = "$HTTPS_PORT" ] || [ "$PANEL_PORT" = "$HTTP_PORT" ]; then
        err "Panel port (${PANEL_PORT}) collides with the port nginx must own (${HTTPS_PORT}/${HTTP_PORT})."
        err "nginx has to listen on ${HTTPS_PORT} to front your CDN inbounds and camouflage site,"
        err "so the x-ui panel CANNOT also use ${PANEL_PORT}. In the x-ui panel, set the web"
        err "'Panel Port' to something internal like 2053 or 8443, then run Install again."
        exit 1
    fi

    if [ "$PANEL_DOMAIN" = "$CDN_DOMAIN" ]; then
        warn "Panel and CDN domain are IDENTICAL. Non-CDN inbounds (Reality/gRPC/"
        warn "Hysteria2) can't coexist with CDN inbounds on the same Cloudflare-"
        warn "proxied hostname."
        local SAMEOK; ask_optional SAMEOK "Continue anyway?" "[y/N]"
        is_yes "$SAMEOK" || { err "Aborted. Provide two different domains."; exit 1; }
    else
        ok "Panel (${PANEL_DOMAIN}) and CDN (${CDN_DOMAIN}) domains are separate. Good."
    fi

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

    if ! openssl x509 -in "$SSL_CERT" -noout >/dev/null 2>&1; then
        err "SSL_CERT is not a valid certificate file."
        exit 1
    fi
    if ! openssl pkey -in "$SSL_KEY" -noout >/dev/null 2>&1 && ! openssl rsa -in "$SSL_KEY" -noout >/dev/null 2>&1; then
        err "SSL_KEY is not a valid private key file."
        exit 1
    fi
    if openssl rsa -in "$SSL_KEY" -noout -modulus >/dev/null 2>&1; then
        local cert_mod key_mod
        cert_mod=$(openssl x509 -in "$SSL_CERT" -noout -modulus 2>/dev/null | openssl md5)
        key_mod=$(openssl rsa -in "$SSL_KEY" -noout -modulus 2>/dev/null | openssl md5)
        if [ "$cert_mod" != "$key_mod" ]; then
            err "Cert/Key do NOT match. Double-check the pair."
            exit 1
        fi
    fi
    ok "Certificate and key validated."

    check_cert_browser_trust "$SSL_CERT" "$CDN_DOMAIN"

    echo -e "${INFO}=== Shared Certificate Validation ===${RESET}"
    local cdn_ok=1 panel_ok=1
    check_cert_covers_domain "$SSL_CERT" "$CDN_DOMAIN" "CDN domain" || cdn_ok=0
    if [ "$PANEL_DOMAIN" != "$CDN_DOMAIN" ]; then
        check_cert_covers_domain "$SSL_CERT" "$PANEL_DOMAIN" "Panel domain" || panel_ok=0
    fi
    if [ "$cdn_ok" -eq 0 ]; then
        err "Certificate doesn't cover the CDN domain. Aborting."
        exit 1
    fi
    if [ "$panel_ok" -eq 0 ]; then
        err "Certificate doesn't cover the panel domain (${PANEL_DOMAIN})."
        err "Panel HTTPS uses this same certificate -- get a SAN/wildcard cert covering both."
        exit 1
    fi

    ensure_cert_renew_hook "$SSL_CERT"

    BEHIND_CF=""
    local __cdn_ip; __cdn_ip=$(resolve_domain_ips "$CDN_DOMAIN" | awk '{print $1}')
    if [ -n "$__cdn_ip" ] && printf '%s' "$__cdn_ip" | grep -qE '^(173\.245\.|103\.21\.|103\.22\.|103\.31\.|141\.101\.|108\.162\.|190\.93\.|188\.114\.|197\.234\.|198\.41\.|162\.158\.|104\.16\.|104\.24\.|172\.6[4-9]\.|172\.7[01]\.|131\.0\.72\.)'; then
        ok "${CDN_DOMAIN} resolves to a Cloudflare IP -- enabling real-IP restore."
        BEHIND_CF="y"
    else
        ok "${CDN_DOMAIN} isn't on a Cloudflare IP right now -- skipping real-IP restore."
    fi

    echo -e "${INFO}=== Inbounds ===${RESET}"
    local DISC
    ask_choice DISC "Discovery mode:" \
        "1:Auto" \
        "2:Manual"

    [ "$DISC" = "1" ] && { auto_build_locations || warn "Auto-build failed. Switching to manual."; }

    if [ "$DISC" = "2" ] || [ -z "$LOCATIONS" ]; then
        ask_number NIN "Inbound Count"
        local i=1
        while [ "$i" -le "$NIN" ]; do
            echo -e "${INFO}--- Inbound #${i} ---${RESET}"
            ask P_PATH "Path"
            [ "${P_PATH:0:1}" = "/" ] || P_PATH="/$P_PATH"
            ask_number P_PORT "Local Port"
            local P_TYPE
            ask_choice P_TYPE "Transport:" \
                "1:WebSocket/HTTPUpgrade" \
                "2:XHTTP"
            case "$P_TYPE" in
                1) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location upgrade "$P_PATH" "$P_PORT" "$PRIMARY")"
                   CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [ws/httpupgrade] ${P_PATH} -> via ${PRIMARY} (manual)"
                   warn "Manual entry does NOT touch x-ui's inbound. In x-ui set this inbound's"
                   warn "Security to 'none' and leave the transport Host EMPTY, or use Auto." ;;
                2) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location xhttp "$P_PATH" "$P_PORT" "$PRIMARY")"
                   CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [xhttp] ${P_PATH} -> via ${PRIMARY} (manual)"
                   warn "Manual entry does NOT touch x-ui's inbound. In x-ui set Security to"
                   warn "'none', leave host EMPTY, and leave XHTTP mode unset/Auto, or use Auto." ;;
            esac
            i=$((i+1))
        done
    fi

    echo -e "${INFO}=== Camouflage ===${RESET}"
    local CAMO
    ask_choice CAMO "Type:" \
        "1:Reverse Proxy" \
        "2:Local HTML"
    if [ "$CAMO" = "1" ]; then
        ask PROXY_URL "Site to mirror"
        PROXY_HOST=$(strip_scheme "$PROXY_URL"); PROXY_SCHEME="https"
        PROXY_BASEPATH=$(printf '%s' "$PROXY_URL" | sed -E 's#^https?://[^/]*##')
        [ -z "$PROXY_BASEPATH" ] && PROXY_BASEPATH="/"
        _build_camo_block
    else
        local AUTO_HTML
        AUTO_HTML=$(find_index_html_auto)
        if [ -n "$AUTO_HTML" ]; then
            ok "Found: ${AUTO_HTML}"
            local USEHTML; ask_optional USEHTML "Use this file?" "[Y/n]"
            case "$USEHTML" in
                n|N|no) ask_file HTML_FILE "Path to index.html" ;;
                *) HTML_FILE="$AUTO_HTML" ;;
            esac
        else
            warn "No index.html found automatically."
            ask_file HTML_FILE "Path to index.html"
        fi

        if [ ! -f "$HTML_FILE" ]; then
            err "Not found: ${HTML_FILE}"
            return 1
        fi
        if [ ! -s "$HTML_FILE" ]; then
            err "File is empty: ${HTML_FILE}"
            return 1
        fi
        mkdir -p "$CAMO_ROOT" || { err "Could not create ${CAMO_ROOT}."; return 1; }
        if ! cp "$HTML_FILE" "$CAMO_ROOT/index.html"; then
            err "Failed to copy ${HTML_FILE}."
            return 1
        fi
        if [ ! -s "$CAMO_ROOT/index.html" ]; then
            err "Copy resulted in an empty file. Aborting."
            return 1
        fi
        ok "index.html installed."
        CAMO_BLOCK="    location / { root ${CAMO_ROOT}; index index.html; }"
    fi
}

version_ge() {
    [ "$1" = "$2" ] && return 0
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}
detect_http2_syntax() {
    local v
    v=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    if [ -n "$v" ] && version_ge "$v" "1.25.1"; then
        HTTP2_LISTEN_SUFFIX=""
        HTTP2_DIRECTIVE="    http2 on;"
    else
        HTTP2_LISTEN_SUFFIX=" http2"
        HTTP2_DIRECTIVE=""
    fi
}

write_config() {
    mkdir -p "$NGINX_CONF_DIR"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null

    is_yes "${BEHIND_CF:-}" && write_cf_realip

    nginx -V 2>&1 | grep -q 'http_sub_module' || {
        err "http_sub_module missing. Run Install again first."
        return 1
    }

    detect_http2_syntax

    local catchall_dir="/etc/nginx/goldip-catchall"
    local catchall_conf="${NGINX_CONF_DIR}/00-goldip-catchall.conf"
    if [ ! -f "${catchall_dir}/catchall.pem" ] || [ ! -f "${catchall_dir}/catchall.key" ]; then
        mkdir -p "$catchall_dir"
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "${catchall_dir}/catchall.key" -out "${catchall_dir}/catchall.pem" \
            -subj "/CN=invalid.goldip.local" >/dev/null 2>&1
    fi
    if [ ! -f "$catchall_conf" ]; then
        {
            echo "# GoldIP default_server catch-all"
            echo "server {"
            echo "    listen ${HTTPS_PORT} ssl${HTTP2_LISTEN_SUFFIX} default_server;"
            [ -n "$HTTP2_DIRECTIVE" ] && echo "$HTTP2_DIRECTIVE"
            echo "    server_name _;"
            echo "    ssl_certificate     ${catchall_dir}/catchall.pem;"
            echo "    ssl_certificate_key ${catchall_dir}/catchall.key;"
            echo "    return 444;"
            echo "}"
            echo ""
            echo "server {"
            echo "    listen ${HTTP_PORT} default_server;"
            echo "    server_name _;"
            echo "    return 444;"
            echo "}"
        } > "$catchall_conf"
        ok "Default-server catch-all written."
    fi

    local conf="${NGINX_CONF_DIR}/${PRIMARY}.conf"
    {
        echo "server {"
        echo "    listen ${HTTP_PORT};"
        echo "    server_name ${CDN_DOMAIN};"
        echo "    server_tokens off;"
        echo "    access_log /var/log/nginx/${PRIMARY}.access.log;"
        echo "    error_log  /var/log/nginx/${PRIMARY}.error.log;"
        printf '%s\n' "${LOCATIONS}"
        echo "${CAMO_BLOCK}"
        echo "}"
        echo ""
        echo "server {"
        echo "    listen ${HTTPS_PORT} ssl${HTTP2_LISTEN_SUFFIX};"
        [ -n "$HTTP2_DIRECTIVE" ] && echo "$HTTP2_DIRECTIVE"
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
        echo "    add_header X-XSS-Protection \"0\" always;"
        echo "    access_log /var/log/nginx/${PRIMARY}.access.log;"
        echo "    error_log  /var/log/nginx/${PRIMARY}.error.log;"
        printf '%s\n' "${LOCATIONS}"
        echo "${CAMO_BLOCK}"
        echo "}"
    } > "$conf"

    if [ "$PANEL_DOMAIN" != "$CDN_DOMAIN" ]; then
        local panel_conf="${NGINX_CONF_DIR}/${PANEL_DOMAIN}.conf"
        local panel_proxy
        panel_proxy=$(cat <<PANELLOC
    client_max_body_size 50m;
    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
PANELLOC
)
        {
            echo "server {"
            echo "    listen ${HTTP_PORT};"
            echo "    server_name ${PANEL_DOMAIN};"
            echo "    server_tokens off;"
            echo "    access_log /var/log/nginx/${PANEL_DOMAIN}.access.log;"
            echo "    error_log  /var/log/nginx/${PANEL_DOMAIN}.error.log;"
            printf '%s\n' "${panel_proxy}"
            echo "}"
            echo ""
            echo "server {"
            echo "    listen ${HTTPS_PORT} ssl${HTTP2_LISTEN_SUFFIX};"
            [ -n "$HTTP2_DIRECTIVE" ] && echo "$HTTP2_DIRECTIVE"
            echo "    server_name ${PANEL_DOMAIN};"
            echo "    ssl_certificate     ${SSL_CERT};"
            echo "    ssl_certificate_key ${SSL_KEY};"
            echo "    ssl_protocols TLSv1.2 TLSv1.3;"
            echo "    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;"
            echo "    ssl_prefer_server_ciphers off;"
            echo "    server_tokens off;"
            echo "    add_header X-Content-Type-Options nosniff always;"
            echo "    add_header X-Frame-Options SAMEORIGIN always;"
            echo "    access_log /var/log/nginx/${PANEL_DOMAIN}.access.log;"
            echo "    error_log  /var/log/nginx/${PANEL_DOMAIN}.error.log;"
            printf '%s\n' "${panel_proxy}"
            echo "}"
        } > "$panel_conf"
        ok "Panel domain block written (${PANEL_DOMAIN}:${HTTP_PORT}+${HTTPS_PORT} -> 127.0.0.1:${PANEL_PORT})."
    fi

    cat > /etc/logrotate.d/goldip-nginx <<LOGROT_EOF
/var/log/nginx/*.access.log /var/log/nginx/*.error.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 \$(cat /var/run/nginx.pid) 2>/dev/null || systemctl reload nginx >/dev/null 2>&1 || true
    endscript
}
LOGROT_EOF
    ok "Logrotate policy installed (daily, 14 rotations)."

    if nginx -t; then
        if systemctl restart nginx; then
            ok "Nginx running on ${HTTPS_PORT} for CDN=${CDN_DOMAIN}, Panel=${PANEL_DOMAIN}!"
        else
            err "nginx -t passed but restart failed. Run: systemctl status nginx -l"
            return 1
        fi
    else
        err "nginx -t FAILED. Config written but NOT activated."
        return 1
    fi

    echo ""
    echo -e "${INFO}================= ROUTING SUMMARY =================${RESET}"
    echo -e "${C4}CDN domain:${RESET}   ${CDN_DOMAIN}  (ws/xhttp/httpupgrade only)"
    echo -e "${C5}Panel domain:${RESET} ${PANEL_DOMAIN}  (-> 127.0.0.1:${PANEL_PORT})"
    if [ -n "$CDN_ROUTED_SUMMARY" ]; then
        echo -e "${CDN_BG} Routed through CDN: ${RESET}"
        echo -e "${CDN_ROUTED_SUMMARY}"
    fi
    if [ -n "$HOSTFIX_SUMMARY" ]; then
        echo -e "${FIX_BG} DB fixed (Host/mode + listen rebound): ${RESET}"
        echo -e "${HOSTFIX_SUMMARY}"
    fi
    if [ -n "$FAILED_SUMMARY" ]; then
        echo -e "${ERR_BG} FAILED (will NOT work): ${RESET}"
        echo -e "${FAILED_SUMMARY}"
    fi
    if [ -n "$NONCDN_SUMMARY" ]; then
        echo -e "${SKIP_BG} Left direct (non-CDN): ${RESET}"
        echo -e "${NONCDN_SUMMARY}"
    fi
    echo -e "${INFO}=====================================================${RESET}"
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
    [ "$hit" -eq 1 ] || warn "Could not whitelist ${GOLDIP_TRUSTED}."
}

# ---------------- Firewall (UFW) ----------------
setup_firewall() {
    command -v ufw >/dev/null 2>&1 || run_with_spinner "Installing ufw" apt-get install -y ufw >/dev/null

    local CDN_CHOICE
    ask_choice CDN_CHOICE "CDN:" \
        "1:Cloudflare" \
        "2:ArvanCloud" \
        "3:Both" \
        "4:Custom"
    local RANGES="" RANGES6=""
    case "$CDN_CHOICE" in
        1) fetch_cloudflare_ranges; RANGES="$CF_V4"; RANGES6="$CF_V6" ;;
        2) fetch_arvan_ranges; RANGES="$ARVAN_V4"; RANGES6="$ARVAN_V6" ;;
        3) fetch_cloudflare_ranges; fetch_arvan_ranges; RANGES="$CF_V4 $ARVAN_V4"; RANGES6="$CF_V6 $ARVAN_V6" ;;
        4) ask RANGES "IPv4 CIDRs"; ask_optional RANGES6 "IPv6 CIDRs" ;;
    esac

    local SSH_PORT FW_HTTPS FW_HTTP TUN_PORT FOREIGN_IP=""
    ask_port SSH_PORT "SSH Port" 22
    ask_port FW_HTTPS "HTTPS Port" 443
    ask_port FW_HTTP  "HTTP Port"  80
    ask_port_optional TUN_PORT "Tunnel Port"
    [ -n "$TUN_PORT" ] && ask_optional FOREIGN_IP "Tunnel IP"

    ufw --force reset >/dev/null; ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
    ufw allow "${SSH_PORT}/tcp" >/dev/null

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
    ok "Firewall configured."

    command -v nginx >/dev/null 2>&1 && {
        local RIP
        case "$CDN_CHOICE" in
            1) ask_optional RIP "Restore real IPs?" "[y/N]"; is_yes "$RIP" && write_realip cloudflare ;;
            2) ask_optional RIP "Restore real IPs?" "[y/N]"; is_yes "$RIP" && write_realip arvan ;;
            3) ask_optional RIP "Restore real IPs? [c/a/blank]"; case "$RIP" in c|C) write_realip cloudflare ;; a|A) write_realip arvan ;; esac ;;
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
    ok "Auto-restart applied."
    [ "$mode" = "silent" ] && return
    systemctl list-unit-files 2>/dev/null | grep -q '^goldip-watchdog\.timer' && ok "Watchdog active." \
        || { local WD; ask_optional WD "Install watchdog?" "[y/N]"; is_yes "$WD" && install_watchdog; }
}

# ---------------- FULL UNINSTALL ----------------
full_uninstall() {
    echo -e "${ERR_BG} WARNING ${RESET} ${C_ERR}This removes Nginx, all configs, logs and the watchdog!${RESET}"
    local CONFIRM; ask_optional CONFIRM "Type YES to confirm"
    [ "$CONFIRM" = "YES" ] || { warn "Cancelled."; return; }

    echo -e "${INFO}--- 1/7 stopping services ---${RESET}"
    systemctl stop nginx 2>&1
    systemctl disable nginx 2>&1
    systemctl stop goldip-watchdog.timer 2>&1
    systemctl disable goldip-watchdog.timer 2>&1

    echo -e "${INFO}--- 2/7 removing watchdog ---${RESET}"
    rm -fv /etc/systemd/system/goldip-watchdog.service \
           /etc/systemd/system/goldip-watchdog.timer \
           /usr/local/bin/goldip-watchdog.sh

    echo -e "${INFO}--- 3/7 removing systemd drop-ins ---${RESET}"
    rm -rfv /etc/systemd/system/nginx.service.d
    rm -fv /etc/systemd/system/multi-user.target.wants/nginx.service 2>/dev/null
    systemctl daemon-reload
    systemctl reset-failed nginx 2>/dev/null

    echo -e "${INFO}--- 4/7 purging nginx packages ---${RESET}"
    run_with_spinner "Purging packages" apt-get purge -y \
        nginx nginx-common nginx-core nginx-light nginx-full nginx-extras \
        libnginx-mod-* 2>&1
    apt-get autoremove -y --purge 2>&1
    apt-get autoclean -y 2>&1

    echo -e "${INFO}--- 5/7 removing files ---${RESET}"
    rm -rfv /etc/nginx
    rm -rfv /var/log/nginx
    rm -rfv /var/www/goldip
    rm -rfv /var/cache/nginx
    rm -rfv /var/lib/nginx
    rm -fv  /etc/logrotate.d/nginx

    echo -e "${INFO}--- 6/7 removing certbot hook ---${RESET}"
    rm -fv /etc/letsencrypt/renewal-hooks/deploy/goldip-nginx-reload.sh

    echo -e "${INFO}--- 7/7 verification ---${RESET}"
    local leftover=0
    if command -v nginx >/dev/null 2>&1; then
        err "nginx binary still present: $(command -v nginx)"
        leftover=1
    fi
    if dpkg -l 2>/dev/null | grep -qE '^ii\s+nginx'; then
        err "dpkg still reports an nginx-* package:"
        dpkg -l | grep -E '^ii\s+nginx'
        leftover=1
    fi
    if [ -d /etc/nginx ]; then
        err "/etc/nginx still exists."
        leftover=1
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
        err "systemd still has nginx.service registered."
        leftover=1
    fi

    if [ "$leftover" -eq 0 ]; then
        ok "Nginx fully uninstalled."
    else
        err "Some leftovers detected above -- review manually."
    fi
}

uninstall_domain() {
    local D; ask D "Domain"
    rm -f "${NGINX_CONF_DIR}/${D}.conf"
    command -v nginx >/dev/null 2>&1 && nginx -t 2>/dev/null && systemctl reload nginx && ok "Removed." || ok "Removed (nginx not running)."
}

colorize_access_line() {
    local line="$1" code
    code=$(printf '%s' "$line" | grep -oE '" [1-5][0-9][0-9] ' | head -n1 | tr -dc '0-9')
    case "$code" in
        5*) echo -e "${ERR_BG} ${code} ${RESET} ${C_ERR}$line${RESET}" ;;
        4*) echo -e "${WARN_BG} ${code} ${RESET} \033[1;33m$line${RESET}" ;;
        2*|3*) echo -e "${OK_BG} ${code} ${RESET} ${C_OK}$line${RESET}" ;;
        *) echo -e "${C8}$line${RESET}" ;;
    esac
}

view_logs() {
    local logdir="/var/log/nginx"; [ -d "$logdir" ] || { err "No logs."; return; }
    local -a LOGS; local f i=0
    for f in "$logdir"/*.log; do [ -f "$f" ] || continue; i=$((i+1)); LOGS[$i]="$f"; done
    [ "$i" -gt 0 ] || { warn "No logs found."; return; }
    echo -e "${INFO}Logs:${RESET}"
    for n in $(seq 1 "$i"); do echo -e "    ${C6}${n}) ${LOGS[$n]}${RESET}"; done
    local PICK; ask_number PICK "Select"
    { [ "$PICK" -ge 1 ] && [ "$PICK" -le "$i" ]; } || return
    tail -n 50 "${LOGS[$PICK]}" | while IFS= read -r line; do colorize_access_line "$line"; done
}

svc() {
    case "$1" in
        start)   systemctl start nginx   && ok "Started"   || err "Start failed" ;;
        stop)    systemctl stop nginx    && ok "Stopped"   || err "Stop failed" ;;
        restart) systemctl restart nginx && ok "Restarted" || err "Restart failed" ;;
        reload)  nginx -t 2>/dev/null && systemctl reload nginx && ok "Reloaded" || err "Reload failed" ;;
    esac
}
show_status() {
    systemctl is-active --quiet nginx && ok "Nginx ACTIVE" || err "Nginx INACTIVE"
    systemctl is-active --quiet x-ui && ok "x-ui ACTIVE" || err "x-ui INACTIVE"
    echo -e "${INFO}--- Listening ports (80/443) ---${RESET}"
    ss -tlnp 2>/dev/null | grep -E ':80 |:443 ' || warn "Nothing listening on 80/443."
    nginx -t 2>&1
}

# ---------------- Main Menu ----------------
do_install() {
    install_nginx || return 1
    ensure_sqlite3
    gather_inputs
    write_config || { err "Install aborted: nginx config invalid. See errors above."; return 1; }
    enable_persistence silent
}

menu() {
    while true; do
        draw_header
        echo -e "  ${C1}1) Install${RESET}"
        echo -e "  ${C2}2) Server Management${RESET}"
        echo -e "  ${C3}3) Domain & Firewall${RESET}"
        echo -e "  ${C4}4) Diagnostics${RESET}"
        echo -e "  ${C5}5) Uninstall${RESET}"
        echo -e "  ${C8}0) Exit${RESET}"
        local CH; ask_optional CH "Choose"
        case "$CH" in
            1) do_install ;;
            2) menu_server_management ;;
            3) menu_domain_firewall ;;
            4) menu_diagnostics ;;
            5) full_uninstall ;;
            0) exit 0 ;;
            *) err "Invalid choice." ;;
        esac
        local _; ask_optional _ "Press Enter to continue..."
    done
}

menu_server_management() {
    while true; do
        draw_header
        echo -e "  ${C1}1) Start${RESET}"
        echo -e "  ${C2}2) Stop${RESET}"
        echo -e "  ${C3}3) Restart${RESET}"
        echo -e "  ${C4}4) Reload${RESET}"
        echo -e "  ${C5}5) Status${RESET}"
        echo -e "  ${C6}6) Logs${RESET}"
        echo -e "  ${C7}7) Auto-Start${RESET}"
        echo -e "  ${C8}0) Back${RESET}"
        local CH; ask_optional CH "Choose"
        case "$CH" in
            1) svc start ;;
            2) svc stop ;;
            3) svc restart ;;
            4) svc reload ;;
            5) show_status ;;
            6) view_logs ;;
            7) enable_persistence ;;
            0) return ;;
            *) err "Invalid choice." ;;
        esac
        local _; ask_optional _ "Press Enter to continue..."
    done
}

menu_domain_firewall() {
    while true; do
        draw_header
        echo -e "  ${C1}1) Remove Domain${RESET}"
        echo -e "  ${C2}2) Firewall Setup${RESET}"
        echo -e "  ${C3}3) Firewall Status${RESET}"
        echo -e "  ${C8}0) Back${RESET}"
        local CH; ask_optional CH "Choose"
        case "$CH" in
            1) uninstall_domain ;;
            2) setup_firewall ;;
            3) firewall_status ;;
            0) return ;;
            *) err "Invalid choice." ;;
        esac
        local _; ask_optional _ "Press Enter to continue..."
    done
}

menu_diagnostics() {
    while true; do
        draw_header
        echo -e "  ${C1}1) Verify CDN Binding${RESET}"
        echo -e "  ${C2}2) Diagnose Disconnects${RESET}"
        echo -e "  ${C8}0) Back${RESET}"
        local CH; ask_optional CH "Choose"
        case "$CH" in
            1) verify_cdn_binding_menu ;;
            2) diagnose_delayed_disconnect ;;
            0) return ;;
            *) err "Invalid choice." ;;
        esac
        local _; ask_optional _ "Press Enter to continue..."
    done
}

require_root; menu
