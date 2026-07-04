#!/bin/bash
# ============================================================
#  GoldIP Nginx Camouflage Installer & Manager  v4.1 (Uncut)
#  CHANGELOG v4.1:
#   - CRITICAL FIX: XHTTP transport was fundamentally broken through nginx.
#     XHTTP's stream-up/stream-one modes carry real HTTP/2 frames (same
#     transport family as gRPC), not plain HTTP/1.1. The previous version
#     proxied xhttp locations with `proxy_pass` + `proxy_http_version 1.1`,
#     which cannot correctly relay HTTP/2 streaming frames -- causing
#     hangs, premature connection closes, or silent failures. Confirmed
#     directly by the Xray-core maintainer (XTLS/Xray-core Discussion
#     #4113: "if it can't get through nginx, change proxy_pass to
#     grpc_pass") and by the official reference config in XTLS/
#     Xray-examples/VLESS-XHTTP3-Nginx (grpc_pass, client_max_body_size 0,
#     extended timeouts, no forced Host header). Fixed: xhttp locations now
#     use grpc_pass (nginx's built-in core gRPC module) exactly matching
#     the official reference. ws/httpupgrade locations are unaffected.
#  CHANGELOG v4.0:
#   - CRITICAL FIX: root-caused "looks like CDN domain in the panel but
#     behaves like the panel domain internally". The x-ui "hosts" table
#     (cosmetic, subscription-URI only) was already correct; the value
#     Xray-core actually used at connection time (wsSettings.headers.Host /
#     httpupgradeSettings.host / xhttpSettings.host inside stream_settings)
#     was never touched by the old script and could carry a stale panel
#     domain forever, invisibly. strip_tls_py now force-rewrites the
#     correct field per transport type on every run.
#   - NEW: default_server catch-all (own dedicated file, written once,
#     shared across all CDN domains) explicitly rejects (444) any TLS/HTTP
#     request whose Host/SNI doesn't match a configured CDN domain.
#   - NEW: auto-locates index.html (checks /root/goldip first per your
#     priority, then common paths, then a bounded filesystem search),
#     shows the user what it found and lets them confirm or override.
#  CHANGELOG v3.9:
#   - NEW: Panel domain and CDN domain are now explicitly
#     separated end-to-end. You can run:
#       * CDN_DOMAIN  -> proxied (orange cloud) through
#         Cloudflare/Arvan, serves ONLY ws/xhttp/httpupgrade
#         inbounds through nginx.
#       * PANEL_DOMAIN -> stays DNS-only (grey cloud) and is
#         used for the x-ui admin panel + any non-CDN inbounds
#         (Reality, gRPC, Hysteria2, etc.) that bypass nginx
#         entirely and would break if Cloudflare-proxied.
#   - NEW: gather_inputs explicitly asks whether the panel
#     domain should be proxied. If the user says yes, a loud
#     warning explains this WILL break non-CDN inbounds (since
#     Cloudflare's proxy only forwards standard HTTP/HTTPS, not
#     arbitrary TCP/UDP protocols like Reality/Hysteria2/gRPC).
#   - NEW: every x-ui "host" record written for a CDN-compatible
#     inbound now explicitly uses CDN_DOMAIN (never PANEL_DOMAIN)
#     for address / sni / host_header — guaranteed by construction,
#     not by convention. insert_host_py signature updated to make
#     this an explicit, named, validated parameter.
#   - NEW: nginx now sends an explicit, hardcoded Host header
#     (proxy_set_header Host <CDN_DOMAIN>) instead of the
#     pass-through "$host" variable for ws/httpupgrade, so the
#     backend xray inbound always receives the CDN domain as
#     Host — never the panel domain — no matter what a client sends.
#   - NEW: shared-certificate validation. If cert is shared
#     between the two domains, the script verifies (via SAN /
#     CN inspection) that the certificate actually covers BOTH
#     CDN_DOMAIN and PANEL_DOMAIN before proceeding, and fails
#     loudly (not silently) if it doesn't.
#   - NEW: end-of-run summary explicitly lists which inbounds are
#     CDN-routed (via CDN_DOMAIN) and which are direct/non-CDN
#     (via PANEL_DOMAIN or raw IP), so there is zero ambiguity
#     about what traffic goes where.
#   - (carried over from v3.8) full vertical colored menu, colored
#     skip/CDN inbound reporting, robust full uninstall, Cloudflare
#     Origin-CA "not private" diagnosis, nginx-extras install fix,
#     nginx -t / restart failures never swallowed, http2 syntax
#     version-aware, cert/key parse+match validation.
# ============================================================
set -uo pipefail

RESET='\033[0m'

# ---------------- Color Palette (256-color ANSI) ----------------
C_OK='\033[1;32m'      # green  - success ONLY
C_ERR='\033[1;31m'     # red    - delete / error ONLY

C_PINK='\033[1;38;5;213m'
C_OLIVE='\033[1;38;5;100m'
C_LPINK='\033[1;38;5;217m'
C_TEALGREY='\033[1;38;5;108m'
C_CHOC='\033[1;38;5;130m'
C_LCHOC='\033[1;38;5;180m'
C_SKY='\033[1;38;5;75m'
C_PURPLE='\033[1;38;5;141m'
C_GOLD='\033[1;38;5;220m'
C_ORANGE='\033[1;38;5;208m'
C_DEEPTEAL='\033[1;38;5;37m'
C_SLATE='\033[1;38;5;103m'
C_ROSE='\033[1;38;5;168m'
C_LIME='\033[1;38;5;154m'

TITLE='\033[1;36m'; INFO='\033[1;34m'
OK_BG='\033[42m\033[97m'; WARN_BG='\033[43m\033[97m'; ERR_BG='\033[41m\033[97m'

SKIP_BG='\033[1;30;43m'   # yellow bg, black text -> skipped (non-CDN) inbound
CDN_BG='\033[1;30;42m'    # green bg,  black text -> CDN-compatible inbound

PALETTE=(C_PINK C_OLIVE C_LPINK C_TEALGREY C_CHOC C_LCHOC C_SKY C_PURPLE C_GOLD C_ORANGE)
__cidx=0
CURCOLOR=""
nextcolor() {
    local name="${PALETTE[$__cidx]}"
    __cidx=$(( (__cidx + 1) % ${#PALETTE[@]} ))
    CURCOLOR="${!name}"
}

ok()   { echo -e "${OK_BG} OK ${RESET} ${C_OK}$1${RESET}"; }
warn() { echo -e "${WARN_BG} WARN ${RESET} \033[1;33m$1${RESET}"; }
err()  { echo -e "${ERR_BG} ERROR ${RESET} ${C_ERR}$1${RESET}"; }

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
        echo -e "${INFO}${__q}${RESET}"
        IFS='|' read -ra __opts <<< "$__valid"
        for __o in "${__opts[@]}"; do
            nextcolor
            echo -e "  ${CURCOLOR}${__o})${RESET}"
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
==========================================================
   ____       _     _ ___ ____
  / ___| ___ | | __| |_ _|  _ \
 | |  _ / _ \| |/ _` || || |_) |
 | |_| | (_) | | (_| || ||  __/
  \____|\___/|_|\__,_|___|_|
    N G I N X   C A M O U F L A G E   v3.9 (Uncut)
==========================================================
EOF
}

require_root() { [ "$(id -u)" -eq 0 ] || { err "Run this script as root."; exit 1; }; }

ensure_sqlite3() { command -v sqlite3 >/dev/null 2>&1 || apt-get install -y sqlite3 >/dev/null 2>&1; }

# ---------------- install nginx WITH http_sub_module from the start ----------------
install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        if nginx -V 2>&1 | grep -q 'http_sub_module'; then
            ok "Nginx already installed (with http_sub_module)."
            return 0
        fi
        warn "Nginx is installed but missing http_sub_module. Reinstalling as nginx-extras..."
    fi

    apt-get update -y >/dev/null 2>&1
    apt-get remove -y nginx nginx-core nginx-light nginx-full nginx-common >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1

    if apt-get install -y nginx-extras > /tmp/goldip_nginx_install.log 2>&1; then
        ok "Nginx (extras build, includes http_sub_module) installed."
    else
        err "Failed to install nginx-extras. Last 20 lines of apt log:"
        tail -n 20 /tmp/goldip_nginx_install.log
        exit 1
    fi

    nginx -V 2>&1 | grep -q 'http_sub_module' || {
        err "http_sub_module STILL missing after install. The camouflage block (sub_filter) cannot work. Aborting."
        exit 1
    }
}

# ---------------- Location Builder ----------------
# NEW v3.9: every location now hardcodes the Host header to CDN_DOMAIN
# explicitly (never passes through $host), guaranteeing the backend xray
# inbound always sees the CDN domain regardless of what a client sent,
# and guaranteeing the panel domain can never leak into inbound routing.
make_location() {
    local t="$1" p="$2" port="$3" hostheader="$4"
    [ "${p:0:1}" != "/" ] && p="/$p"
    if [ "$t" = "xhttp" ]; then
        # ---------------- v4.1 CRITICAL FIX ----------------
        # ROOT CAUSE of "XHTTP doesn't work through nginx": XHTTP's stream-up
        # and stream-one modes ride on real HTTP/2 frames (the same way gRPC
        # does), NOT plain HTTP/1.1 request/response. The previous version
        # used `proxy_pass` + `proxy_http_version 1.1`, which is the WRONG
        # directive for this traffic -- nginx's proxy_pass module doesn't
        # correctly relay HTTP/2 streaming frames, so the connection either
        # hangs, gets prematurely closed, or silently fails.
        #
        # This is confirmed directly by the Xray-core maintainer (XTLS/
        # Xray-core Discussion #4113): "if it can't get through nginx,
        # change nginx's proxy_pass to grpc_pass" -- and by the OFFICIAL
        # reference nginx.conf in XTLS/Xray-examples/VLESS-XHTTP3-Nginx,
        # which uses grpc_pass, client_max_body_size 0, and extended
        # timeouts -- with NO Host header set at all (XHTTP's own protocol
        # framing carries what it needs; forcing a Host header here does
        # nothing useful and isn't part of the working reference config).
        #
        # Fix: use grpc_pass (nginx's built-in ngx_http_grpc_module -- part
        # of stock nginx core, no extra package needed) instead of
        # proxy_pass, matching the official example exactly.
        printf '    location %s {\n' "$p"
        printf '        client_max_body_size 0;\n'
        printf '        client_body_timeout 5m;\n'
        printf '        grpc_read_timeout 315;\n'
        printf '        grpc_send_timeout 5m;\n'
        printf '        grpc_set_header X-Real-IP $remote_addr;\n'
        printf '        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
        printf '        grpc_set_header X-Forwarded-Proto $scheme;\n'
        printf '        grpc_pass grpc://127.0.0.1:%s;\n' "$port"
        printf '    }\n'
    else
        printf '    location %s {\n' "$p"
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

# NEW v3.9: insert_host_py now takes address/sni/host_header as ONE explicit
# parameter ($4 = cdn_host) that the caller MUST pass as CDN_DOMAIN. There is
# no code path where PANEL_DOMAIN can end up here — callers only ever have
# $PRIMARY (== CDN_DOMAIN) in scope at the call site (see auto_build_locations).
insert_host_py() {
    python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PYEOF'
import sqlite3, sys, time
db_path, inbound_id, remark, cdn_host, port, sni, alpn_json = sys.argv[1:8]
now_ms = int(time.time() * 1000)
try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("""
        INSERT INTO hosts (
            inbound_id, sort_order, remark, server_description, is_disabled, is_hidden,
            address, port, security, sni, host_header, path, alpn, fingerprint, override_sni_from_address,
            keep_sni_blank, allow_insecure, created_at, updated_at
        ) VALUES (?, 0, ?, '', 0, 0, ?, ?, 'tls', ?, ?, '', ?, 'chrome', 1, 0, 0, ?, ?)
    """, (int(inbound_id), remark, cdn_host, int(port), sni, cdn_host, alpn_json, now_ms, now_ms))
    con.commit(); con.close(); print("OK"); sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)
PYEOF
}

# ---------------- v4.0 CRITICAL FIX ----------------
# ROOT CAUSE of "looks like CDN domain in the panel but actually connects
# via the panel domain internally": the x-ui "hosts" table (cosmetic --
# used only to build the subscription URI shown to the user) was already
# set to CDN_DOMAIN correctly. BUT the value Xray-core actually uses at
# connection time lives inside inbounds.stream_settings itself:
#   - ws:          wsSettings.headers.Host
#   - httpupgrade: httpupgradeSettings.host   (a direct string field, not headers!)
#   - xhttp:       xhttpSettings.host         (a direct string field, not headers!)
# The old strip_tls_py never touched these. If an inbound had been created
# manually before running this script (or carried a stale Host from an old
# panel-domain setup), that value stayed forever -- invisible in the panel
# UI but very much alive to Xray-core. Fix: strip_tls_py now takes the CDN
# domain as an explicit 4th argument and FORCE-OVERWRITES the correct
# field for each transport type every time it runs.
strip_tls_py() {
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import sqlite3, json, sys
try:
    con = sqlite3.connect(sys.argv[1]); cur = con.cursor()
    inb_id = int(sys.argv[2]); net = sys.argv[3]; cdn_host = sys.argv[4]
    cur.execute("SELECT stream_settings FROM inbounds WHERE id=?", (inb_id,))
    row = cur.fetchone()
    if row and row[0]:
        ss = json.loads(row[0])
        ss["security"] = "none"
        for k in ("tlsSettings", "realitySettings", "externalProxy", "externalProxySettings"):
            ss.pop(k, None)

        # Force the ACTUAL transport-level Host that Xray-core uses at
        # handshake time to the CDN domain, overwriting any stale
        # panel-domain / blank / manually-set value unconditionally.
        if net == "ws":
            ws = ss.setdefault("wsSettings", {})
            headers = ws.setdefault("headers", {})
            headers["Host"] = cdn_host
        elif net == "httpupgrade":
            hu = ss.setdefault("httpupgradeSettings", {})
            hu["host"] = cdn_host
        elif net in ("xhttp", "splithttp"):
            s_key = net + "Settings"
            xs = ss.setdefault(s_key, {})
            xs["host"] = cdn_host
            extra = xs.setdefault("extra", {})
            extra["xpaddingBytes"] = "100-1000"

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
        warn "Detected a Cloudflare ORIGIN certificate (issuer: ${issuer#issuer=})."
        warn "Origin CA certificates are ONLY trusted between Cloudflare's edge and your server."
        warn "Real browsers will ALWAYS show 'Your connection is not private' for this cert"
        warn "UNLESS the domain is Proxied (orange cloud) through Cloudflare, with SSL mode"
        warn "set to Full or Full (strict) in the Cloudflare dashboard."
        echo ""

        resolved_ip=$(resolve_domain_ips "$domain")
        if [ -n "$resolved_ip" ]; then
            local sample_ip; sample_ip=$(printf '%s' "$resolved_ip" | awk '{print $1}')
            if printf '%s' "$sample_ip" | grep -qE '^(173\.245\.|103\.21\.|103\.22\.|103\.31\.|141\.101\.|108\.162\.|190\.93\.|188\.114\.|197\.234\.|198\.41\.|162\.158\.|104\.16\.|104\.24\.|172\.6[4-9]\.|172\.7[01]\.|131\.0\.72\.)'; then
                ok "DNS check: ${domain} resolves to ${sample_ip}, which IS a Cloudflare IP range (Proxied / orange cloud). Good."
            else
                err "DNS check: ${domain} resolves to ${sample_ip}, which is NOT a Cloudflare IP."
                err "This means the domain is DNS-only (grey cloud) and browsers connect DIRECTLY"
                err "to your server, where they see the Origin Cert and reject it."
                err "Fix: in the Cloudflare dashboard -> DNS -> click the grey cloud next to"
                err "${domain} to turn it orange (Proxied), then wait 1-2 minutes and retest."
            fi
        else
            warn "Could not resolve ${domain} from this server to verify Cloudflare proxy status."
        fi
        echo ""
        local CONT; ask_optional CONT "Continue anyway with this certificate?" "[y/N]"
        is_yes "$CONT" || { err "Aborted by user. Fix the Cloudflare proxy/cert setup and re-run."; exit 1; }
    else
        ok "Certificate issuer does not look like a Cloudflare Origin CA cert. OK for direct browser trust."
    fi
}

# NEW v3.9: verify a shared certificate actually covers BOTH domains
# (SAN list, or CN as fallback for very old certs). Fails loudly if it
# doesn't, rather than letting nginx silently serve a cert that doesn't
# match one of the two server_names.
check_cert_covers_domain() {
    local cert="$1" domain="$2" label="$3"
    local san cn

    san=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | tr -d ' ' | tr ',' '\n' | grep -oE 'DNS:[^,]+' | sed 's/^DNS://')
    cn=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | grep -oE 'CN\s*=\s*[^,/]+' | sed -E 's/CN\s*=\s*//')

    local covered=0
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        if [ "$name" = "$domain" ]; then covered=1; break; fi
        # wildcard match: *.example.com covers sub.example.com (one level)
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
        err "Certificate SAN list: $(printf '%s' "$san" | tr '\n' ' ')"
        err "Certificate CN: ${cn}"
        return 1
    fi
}

# ---------------- Auto Build Locations ----------------
# NEW v3.9: end-of-run summary tracks CDN-routed vs non-CDN inbounds
# explicitly so the user sees exactly what goes through CDN_DOMAIN and
# what stays direct/panel-only.
CDN_ROUTED_SUMMARY=""
NONCDN_SUMMARY=""

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
    local -a OP_IDS OP_FPORTS OP_NETS OP_PATHS OP_ALPNS
    local op_count=0 ltype fport

    for n in $(seq 1 "$idx"); do
        net="${IN_NET[$n]}"; port="${IN_PORT[$n]}"; path="${IN_PATH[$n]}"; id="${IN_ID[$n]}"; remark="${IN_REMARK[$n]}"

        case "$net" in
            ws|httpupgrade) ltype="upgrade" ;;
            xhttp|splithttp) ltype="xhttp" ;;
            *)
                echo -e "${SKIP_BG} SKIPPED (non-CDN) ${RESET} ${net} \"${remark}\" (Port ${port}) — stays DIRECT on ${PANEL_DOMAIN:-server IP}, bypasses nginx/CDN entirely."
                NONCDN_SUMMARY="${NONCDN_SUMMARY}"$'\n'"  - [${net}] \"${remark}\" on port ${port} -> direct via ${PANEL_DOMAIN:-<server IP>} (NOT behind CDN)"
                continue ;;
        esac

        [ -z "$path" ] || [ "$path" = "/" ] && continue
        fport="$port"
        if [ "$port" = "$HTTPS_PORT" ] || [ "$port" = "$HTTP_PORT" ]; then fport=$(free_port); fi
        TAKEN_PORTS="${TAKEN_PORTS} ${fport}"
        
        op_count=$((op_count+1))
        OP_IDS[$op_count]="$id"; OP_FPORTS[$op_count]="$fport"; OP_NETS[$op_count]="$net"
        OP_PATHS[$op_count]="$path"; OP_ALPNS[$op_count]=$(alpn_for_net "$net")

        # NEW v3.9: Host header for this location is ALWAYS CDN_DOMAIN (PRIMARY),
        # explicitly, never the panel domain.
        LOCATIONS="${LOCATIONS}"$'\n'"$(make_location "$ltype" "$path" "$fport" "$PRIMARY")"
        echo -e "${CDN_BG} CDN-OK ${RESET} ${net} \"${remark}\" ${path} -> 127.0.0.1:${fport} (Host header: ${PRIMARY}, exposed via CDN_DOMAIN:443)"
        CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [${net}] \"${remark}\" ${path} -> via ${PRIMARY} (CDN-proxied)"
        added=$((added+1))
    done

    [ "$added" -eq 0 ] && { warn "No CDN-compatible inbounds found."; return 1; }
    local AP; ask_optional AP "Apply DB changes (Inject xPadding + Rebuild Hosts with CDN_DOMAIN=${PRIMARY})?" "[y/N]"
    if is_yes "$AP"; then
        cp "$db" "${db}.bak.$(date +%s)"
        for m in $(seq 1 "$op_count"); do
            mid="${OP_IDS[$m]}"; mfport="${OP_FPORTS[$m]}"; mnet="${OP_NETS[$m]}"; malpn="${OP_ALPNS[$m]}"
            sqlite3 "$db" "UPDATE inbounds SET listen='127.0.0.1', port=${mfport} WHERE id=${mid};"
            strip_tls_py "$db" "$mid" "$mnet" "$PRIMARY" >/dev/null
            sqlite3 "$db" "DELETE FROM hosts WHERE inbound_id=${mid};"
            # NEW v3.9: address/sni/host_header for the x-ui "hosts" record
            # is explicitly $PRIMARY (== CDN_DOMAIN), passed by name, never
            # derived from the panel domain.
            insert_host_py "$db" "$mid" "$mnet" "$PRIMARY" "443" "$PRIMARY" "$malpn" >/dev/null
        done
        ok "Database updated (all CDN inbound hosts point to ${PRIMARY})! Restarting x-ui..."; systemctl restart x-ui
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

# ---------------- v4.0: auto-locate index.html to speed up install ----------------
# Checks common install locations first (fastest, most likely hits), then
# falls back to a bounded filesystem search (maxdepth 4, skipping heavy/
# irrelevant dirs like node_modules and .git) across the usual places
# someone would have dropped a camouflage page. Returns the first match.
# This never silently picks a file without the user seeing/confirming it --
# gather_inputs always shows the found path and lets the user accept or
# override it with a manual path.
find_index_html_auto() {
    # NOTE: CAMO_ROOT (/var/www/goldip) is deliberately NOT in this list.
    # That path is the script's own OUTPUT destination (where index.html
    # gets copied TO). Including it as a candidate SOURCE would mean that
    # on a second run, the script "auto-finds" the file it wrote on the
    # previous run and offers to copy it onto itself -- harmless but
    # pointless and misleading. Only real candidate source locations go here.
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
    CDN_ROUTED_SUMMARY=""; NONCDN_SUMMARY=""

    echo -e "${INFO}=== Panel Configuration ===${RESET}"
    ask RAW_PANEL "Panel Domain / IP" "(e.g. panel.example.com — used ONLY for the x-ui admin panel + non-CDN inbounds)"
    PANEL_DOMAIN=$(strip_scheme "$RAW_PANEL"); PANEL_DOMAIN=$(strip_port "$PANEL_DOMAIN")
    ask_port PANEL_PORT "Panel Port" 2053

    echo -e "${INFO}=== CDN Configuration ===${RESET}"
    ask RAW_CDN "CDN Domain" "(e.g. cdn.example.com — this is the ONLY domain that goes through Cloudflare/Arvan proxy)"
    CDN_DOMAIN=$(strip_scheme "$RAW_CDN"); PRIMARY="$CDN_DOMAIN"
    ask_port HTTPS_PORT "HTTPS Port" 443
    ask_port HTTP_PORT  "HTTP Port"  80

    # NEW v3.9: enforce panel/CDN separation explicitly
    if [ "$PANEL_DOMAIN" = "$CDN_DOMAIN" ]; then
        warn "Panel domain and CDN domain are IDENTICAL (${CDN_DOMAIN})."
        warn "This means you will NOT be able to run non-CDN inbounds (Reality/gRPC/Hysteria2)"
        warn "alongside CDN inbounds, because Cloudflare's proxy only forwards standard HTTP/S,"
        warn "not arbitrary protocols on arbitrary ports."
        local SAMEOK; ask_optional SAMEOK "Continue with panel == CDN domain anyway?" "[y/N]"
        is_yes "$SAMEOK" || { err "Aborted. Re-run and provide two different domains for panel and CDN."; exit 1; }
    else
        ok "Panel domain (${PANEL_DOMAIN}) and CDN domain (${CDN_DOMAIN}) are separate. Good — this is the recommended setup."
    fi

    # NEW v3.9: ask explicitly whether the panel domain will be Cloudflare-proxied
    echo -e "${INFO}=== Panel Domain CDN-Proxy Status ===${RESET}"
    ask_optional PANEL_PROXIED "Will ${PANEL_DOMAIN} be Cloudflare/Arvan PROXIED (orange cloud)?" "[y/N] (choose N to keep it DNS-only for non-CDN inbounds)"
    if is_yes "${PANEL_PROXIED:-}"; then
        warn "You chose to proxy the PANEL domain too."
        warn "Any non-CDN inbound (Reality, gRPC direct, Hysteria2/UDP, etc.) bound to ${PANEL_DOMAIN}"
        warn "will likely BREAK, because Cloudflare's proxy does not forward arbitrary TCP/UDP —"
        warn "only standard HTTP(S) traffic on 80/443 gets proxied correctly."
        local PROXYOK; ask_optional PROXYOK "Understood — continue anyway?" "[y/N]"
        is_yes "$PROXYOK" || { err "Aborted. Re-run and keep the panel domain DNS-only (grey cloud) instead."; exit 1; }
    else
        ok "Panel domain will stay DNS-only — non-CDN inbounds (Reality/gRPC/Hysteria2) will work normally on it."
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
        err "SSL_CERT (${SSL_CERT}) is not a valid certificate file (openssl could not parse it)."
        exit 1
    fi
    if ! openssl pkey -in "$SSL_KEY" -noout >/dev/null 2>&1 && ! openssl rsa -in "$SSL_KEY" -noout >/dev/null 2>&1; then
        err "SSL_KEY (${SSL_KEY}) is not a valid private key file (openssl could not parse it)."
        exit 1
    fi
    if openssl rsa -in "$SSL_KEY" -noout -modulus >/dev/null 2>&1; then
        local cert_mod key_mod
        cert_mod=$(openssl x509 -in "$SSL_CERT" -noout -modulus 2>/dev/null | openssl md5)
        key_mod=$(openssl rsa -in "$SSL_KEY" -noout -modulus 2>/dev/null | openssl md5)
        if [ "$cert_mod" != "$key_mod" ]; then
            err "SSL_CERT and SSL_KEY do NOT match (modulus mismatch). Double-check the cert/key pair."
            exit 1
        fi
    fi
    ok "Certificate and key validated successfully (parse + match OK)."

    check_cert_browser_trust "$SSL_CERT" "$CDN_DOMAIN"

    # NEW v3.9: confirm the (allegedly shared) certificate actually covers
    # BOTH domains before we let anything else proceed, IF the panel is
    # also going to be served TLS from the same cert (i.e. panel is proxied
    # OR the user explicitly wants nginx to also terminate TLS for panel).
    echo -e "${INFO}=== Shared Certificate Validation ===${RESET}"
    local cdn_ok=1 panel_ok=1
    check_cert_covers_domain "$SSL_CERT" "$CDN_DOMAIN" "CDN domain" || cdn_ok=0
    if [ "$PANEL_DOMAIN" != "$CDN_DOMAIN" ]; then
        check_cert_covers_domain "$SSL_CERT" "$PANEL_DOMAIN" "Panel domain" || panel_ok=0
    fi
    if [ "$cdn_ok" -eq 0 ]; then
        err "Certificate does not cover the CDN domain (${CDN_DOMAIN}). This WILL cause browser TLS errors. Aborting."
        exit 1
    fi
    if [ "$panel_ok" -eq 0 ]; then
        warn "Certificate does NOT cover the panel domain (${PANEL_DOMAIN})."
        warn "This is only a problem if you intend nginx/panel to present TLS for ${PANEL_DOMAIN} using this same cert."
        local PCONT; ask_optional PCONT "Continue anyway?" "[y/N]"
        is_yes "$PCONT" || { err "Aborted. Get a certificate (or SAN) that covers ${PANEL_DOMAIN} as well, or use a separate cert for the panel."; exit 1; }
    fi

    ensure_cert_renew_hook "$SSL_CERT"

    ask_optional BEHIND_CF "Behind Cloudflare CDN? (restore real visitor IP in nginx for the CDN domain)" "[y/N]"

    echo -e "${INFO}=== Inbounds ===${RESET}"
    local DISC; ask_choice DISC "Inbound discovery mode:" "1|2"
    echo -e "    ${C_PINK}1) Auto (read from x-ui DB)${RESET}"
    echo -e "    ${C_OLIVE}2) Manual entry${RESET}"

    [ "$DISC" = "1" ] && { auto_build_locations || warn "Auto-build failed or skipped. Switching to manual."; }
    
    if [ "$DISC" = "2" ] || [ -z "$LOCATIONS" ]; then
        ask_number NIN "How many CDN inbounds to add to Nginx?"
        local i=1
        while [ "$i" -le "$NIN" ]; do
            echo -e "${INFO}--- Inbound #${i} ---${RESET}"
            ask P_PATH "Path" "(e.g. /ws${i})"
            [ "${P_PATH:0:1}" = "/" ] || P_PATH="/$P_PATH"
            ask_number P_PORT "Local Xray port"
            echo -e "${INFO}Transport:${RESET}"
            echo -e "    ${C_PINK}1) WebSocket / HTTPUpgrade${RESET}"
            echo -e "    ${C_OLIVE}2) XHTTP${RESET}"
            ask_choice P_TYPE "Selection" "1|2"
            case "$P_TYPE" in
                1) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location upgrade "$P_PATH" "$P_PORT" "$PRIMARY")"
                   CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [ws/httpupgrade] ${P_PATH} -> via ${PRIMARY} (manual entry)" ;;
                2) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location xhttp "$P_PATH" "$P_PORT" "$PRIMARY")"
                   CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [xhttp] ${P_PATH} -> via ${PRIMARY} (manual entry)" ;;
            esac
            i=$((i+1))
        done
    fi

    echo -e "${INFO}=== Camouflage ===${RESET}"
    ask_choice CAMO "Camouflage type:" "1|2"
    echo -e "    ${C_PINK}1) Reverse Proxy (mirror a real website)${RESET}"
    echo -e "    ${C_OLIVE}2) Local HTML (serve your own index.html)${RESET}"
    if [ "$CAMO" = "1" ]; then
        ask PROXY_URL "Website to proxy (e.g. example.com)"
        PROXY_HOST=$(strip_scheme "$PROXY_URL"); PROXY_SCHEME="https"
        PROXY_BASEPATH=$(printf '%s' "$PROXY_URL" | sed -E 's#^https?://[^/]*##')
        [ -z "$PROXY_BASEPATH" ] && PROXY_BASEPATH="/"
        _build_camo_block
    else
        # v4.0: try to auto-locate index.html first to speed up install.
        local AUTO_HTML
        AUTO_HTML=$(find_index_html_auto)
        if [ -n "$AUTO_HTML" ]; then
            ok "Auto-found index.html at: ${AUTO_HTML}"
            local USEHTML; ask_optional USEHTML "Use this file?" "[Y/n]"
            case "$USEHTML" in
                n|N|no) ask_file HTML_FILE "Path to index.html" ;;
                *) HTML_FILE="$AUTO_HTML" ;;
            esac
        else
            warn "No index.html found automatically in common locations (/root, /root/goldip, /var/www/html, current dir)."
            ask_file HTML_FILE "Path to index.html"
        fi
        mkdir -p "$CAMO_ROOT"; cp "$HTML_FILE" "$CAMO_ROOT/index.html"
        CAMO_BLOCK="location / { root ${CAMO_ROOT}; index index.html; }"
    fi
}

# ---------------- nginx version-aware http2 syntax ----------------
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

# NEW v3.9: write_config now ONLY ever writes a server block for CDN_DOMAIN
# (server_name is CDN_DOMAIN, not panel domain). The panel is deliberately
# left OUT of this nginx vhost so it is never accidentally routed through
# the CDN-facing config. The x-ui panel continues to serve itself directly
# on PANEL_PORT via its own domain, entirely separate from this file.
write_config() {
    mkdir -p "$NGINX_CONF_DIR"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null

    is_yes "${BEHIND_CF:-}" && write_cf_realip

    nginx -V 2>&1 | grep -q 'http_sub_module' || {
        err "http_sub_module is missing. Run option 1 again (it reinstalls nginx-extras) before continuing."
        return 1
    }

    detect_http2_syntax

    # v4.0: write the default_server catch-all to its OWN dedicated file
    # (00-catchall.conf), written only once, NOT inside ${PRIMARY}.conf.
    # Rationale: nginx allows only ONE default_server per listen address:port.
    # If this block lived inside each per-domain .conf file, adding a second
    # CDN domain later would create two conflicting default_server
    # declarations and nginx -t would fail. Keeping it in a single shared
    # file guarantees it only ever exists once, no matter how many CDN
    # domains are configured over time.
    #
    # Purpose: any TLS/HTTP request whose Host/SNI does not match a
    # configured CDN domain (e.g. a stale client profile still pointing at
    # PANEL_DOMAIN, or a random IP scanner hitting the raw server IP) is
    # explicitly and loudly rejected (444) instead of nginx silently
    # falling through to whichever server block happens to match first.
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
            echo "# GoldIP default_server catch-all (written once, shared across all"
            echo "# CDN domains configured by this script). Rejects any request whose"
            echo "# Host/SNI does not match a configured CDN domain."
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
        ok "Default-server catch-all written to ${catchall_conf} (rejects non-CDN Host/SNI on ${HTTP_PORT}/${HTTPS_PORT})."
    fi

    local conf="${NGINX_CONF_DIR}/${PRIMARY}.conf"
    {
        echo "server {"
        echo "    listen ${HTTP_PORT};"
        echo "    server_name ${CDN_DOMAIN};"
        echo "    return 301 https://\$host\$request_uri;"
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
        echo "    add_header Strict-Transport-Security \"max-age=63072000; includeSubDomains\" always;"
        echo "    add_header X-XSS-Protection \"0\" always;"
        
        echo "    access_log /var/log/nginx/${PRIMARY}.access.log;"
        echo "    error_log  /var/log/nginx/${PRIMARY}.error.log;"
        
        printf '%s\n' "${LOCATIONS}"
        echo "    ${CAMO_BLOCK}"
        echo "}"
    } > "$conf"

    if nginx -t; then
        if systemctl restart nginx; then
            ok "Nginx Configured & Running on HTTPS (${HTTPS_PORT}) for CDN_DOMAIN=${CDN_DOMAIN}!"
        else
            err "nginx -t passed but 'systemctl restart nginx' failed. Run: systemctl status nginx -l"
            return 1
        fi
    else
        err "nginx -t FAILED (see errors above). HTTPS config was written to ${conf} but NOT activated."
        return 1
    fi

    # NEW v3.9: final routing summary — zero ambiguity about what's CDN vs direct
    echo ""
    echo -e "${INFO}================= ROUTING SUMMARY =================${RESET}"
    echo -e "${C_LIME}CDN-proxied domain:${RESET}   ${CDN_DOMAIN}  (behind Cloudflare/Arvan, nginx terminates TLS here)"
    echo -e "${C_ROSE}Panel domain:${RESET}          ${PANEL_DOMAIN}  ($(is_yes "${PANEL_PROXIED:-}" && echo "PROXIED — non-CDN inbounds may break" || echo "DNS-only — safe for non-CDN inbounds"))"
    if [ -n "$CDN_ROUTED_SUMMARY" ]; then
        echo -e "${CDN_BG} Inbounds routed through CDN_DOMAIN: ${RESET}"
        echo -e "${CDN_ROUTED_SUMMARY}"
    fi
    if [ -n "$NONCDN_SUMMARY" ]; then
        echo -e "${SKIP_BG} Inbounds left DIRECT (non-CDN, use PANEL_DOMAIN/IP): ${RESET}"
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
    [ "$hit" -eq 1 ] || warn "Failed to whitelist ${GOLDIP_TRUSTED} (or domain not resolvable)."
}

# ---------------- Firewall (UFW) ----------------
setup_firewall() {
    command -v ufw >/dev/null 2>&1 || apt-get install -y ufw >/dev/null
    
    echo -e "${INFO}CDN Provider:${RESET}"
    echo -e "    ${C_PINK}1) Cloudflare${RESET}"
    echo -e "    ${C_OLIVE}2) ArvanCloud${RESET}"
    echo -e "    ${C_LPINK}3) Both${RESET}"
    echo -e "    ${C_TEALGREY}4) Custom${RESET}"
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

# ---------------- FULL UNINSTALL ----------------
full_uninstall() {
    echo -e "${ERR_BG} WARNING ${RESET} ${C_ERR}This will COMPLETELY remove Nginx, all configs, logs and the watchdog!${RESET}"
    local CONFIRM; ask_optional CONFIRM "Type YES to confirm"
    [ "$CONFIRM" = "YES" ] || { warn "Cancelled."; return; }

    echo -e "${INFO}--- Step 1/7: stopping services ---${RESET}"
    systemctl stop nginx 2>&1
    systemctl disable nginx 2>&1
    systemctl stop goldip-watchdog.timer 2>&1
    systemctl disable goldip-watchdog.timer 2>&1

    echo -e "${INFO}--- Step 2/7: removing watchdog ---${RESET}"
    rm -fv /etc/systemd/system/goldip-watchdog.service \
           /etc/systemd/system/goldip-watchdog.timer \
           /usr/local/bin/goldip-watchdog.sh

    echo -e "${INFO}--- Step 3/7: removing systemd drop-ins / overrides ---${RESET}"
    rm -rfv /etc/systemd/system/nginx.service.d
    rm -fv /etc/systemd/system/multi-user.target.wants/nginx.service 2>/dev/null
    systemctl daemon-reload
    systemctl reset-failed nginx 2>/dev/null

    echo -e "${INFO}--- Step 4/7: purging ALL nginx packages ---${RESET}"
    apt-get purge -y \
        nginx nginx-common nginx-core nginx-light nginx-full nginx-extras \
        libnginx-mod-* 2>&1
    apt-get autoremove -y --purge 2>&1
    apt-get autoclean -y 2>&1

    echo -e "${INFO}--- Step 5/7: removing remaining files/directories ---${RESET}"
    rm -rfv /etc/nginx
    rm -rfv /var/log/nginx
    rm -rfv /var/www/goldip
    rm -rfv /var/cache/nginx
    rm -rfv /var/lib/nginx
    rm -fv  /etc/logrotate.d/nginx

    echo -e "${INFO}--- Step 6/7: removing certbot renewal hook (GoldIP-installed only) ---${RESET}"
    rm -fv /etc/letsencrypt/renewal-hooks/deploy/goldip-nginx-reload.sh

    echo -e "${INFO}--- Step 7/7: verification ---${RESET}"
    local leftover=0
    if command -v nginx >/dev/null 2>&1; then
        err "nginx binary STILL present at: $(command -v nginx)"
        leftover=1
    fi
    if dpkg -l 2>/dev/null | grep -qE '^ii\s+nginx'; then
        err "dpkg still reports an nginx-* package as installed:"
        dpkg -l | grep -E '^ii\s+nginx'
        leftover=1
    fi
    if [ -d /etc/nginx ]; then
        err "/etc/nginx still exists."
        leftover=1
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
        err "systemd still has an nginx.service unit registered."
        leftover=1
    fi

    if [ "$leftover" -eq 0 ]; then
        ok "Nginx fully uninstalled — no binary, package, config, log, or systemd unit remains."
    else
        err "Uninstall finished but some leftovers were detected above. Review and remove manually if needed."
    fi
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
        5*) echo -e "${ERR_BG} ${code} ${RESET} ${C_ERR}$line${RESET}" ;;
        4*) echo -e "${WARN_BG} ${code} ${RESET} \033[1;33m$line${RESET}" ;;
        2*|3*) echo -e "${OK_BG} ${code} ${RESET} ${C_OK}$line${RESET}" ;;
        *) echo -e "${C_TEALGREY}$line${RESET}" ;;
    esac
}

view_logs() {
    local logdir="/var/log/nginx"; [ -d "$logdir" ] || { err "No logs."; return; }
    local -a LOGS; local f i=0
    for f in "$logdir"/*.log; do [ -f "$f" ] || continue; i=$((i+1)); LOGS[$i]="$f"; done
    [ "$i" -gt 0 ] || { warn "No logs found."; return; }
    echo -e "${INFO}Logs:${RESET}"
    for n in $(seq 1 "$i"); do echo -e "    ${C_SKY}${n}) ${LOGS[$n]}${RESET}"; done
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
    echo -e "${INFO}--- Listening ports (80/443) ---${RESET}"
    ss -tlnp 2>/dev/null | grep -E ':80 |:443 ' || warn "Nothing listening on 80/443."
    nginx -t 2>&1
}

# ---------------- Main Menu ----------------
do_install() {
    install_nginx || return 1
    ensure_sqlite3
    gather_inputs
    write_config || { err "Install ABORTED: nginx config did not pass nginx -t / restart. Scroll up for the exact error."; return 1; }
    enable_persistence silent
}

menu() {
    while true; do
        clear; echo -e "${TITLE}"; header; echo -e "${RESET}"
        echo -e "  ${C_PINK}1)  Install / Config website${RESET}"
        echo -e "  ${C_OLIVE}2)  Start Nginx${RESET}"
        echo -e "  ${C_LPINK}3)  Stop Nginx${RESET}"
        echo -e "  ${C_TEALGREY}4)  Restart Nginx${RESET}"
        echo -e "  ${C_CHOC}5)  Reload Nginx${RESET}"
        echo -e "  ${C_LCHOC}6)  Status${RESET}"
        echo -e "  ${C_SKY}7)  View logs${RESET}"
        echo -e "  ${C_PURPLE}8)  Remove domain config${RESET}"
        echo -e "  ${C_GOLD}9)  Setup firewall${RESET}"
        echo -e "  ${C_ORANGE}10) Firewall status${RESET}"
        echo -e "  ${C_DEEPTEAL}11) Fix auto-start (persistence)${RESET}"
        echo -e "  ${C_ERR}12) FULL Nginx uninstall + cleanup${RESET}"
        echo -e "  ${C_ERR}0)  Exit${RESET}"
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
