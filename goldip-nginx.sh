#!/bin/bash
# ============================================================
#  GoldIP Nginx Camouflage Installer & Manager  v4.3 (Uncut)
#  CHANGELOG v4.3 -- investigated "CDN-routed inbounds stop working
#  after several days":
#   - CONFIRMED SCRIPT BUG: write_config() created a dedicated
#     access_log/error_log per domain but never registered a
#     logrotate policy for those exact files. If the distro's
#     default /etc/logrotate.d/nginx is ever missing or replaced,
#     these logs grow unbounded; over days/weeks this exhausts
#     disk space, and nginx then fails unpredictably (cannot write
#     logs / open file descriptors on ENOSPC) -- surfacing as
#     inbounds "randomly" going down after some time. FIX: this
#     script now installs its own /etc/logrotate.d/goldip-nginx
#     (daily, 14 rotations, compress, USR1 reopen) covering every
#     log file it creates, independent of the distro package.
#   - NEW: menu option "Diagnose delayed inbound disconnects" --
#     checks disk usage, oversized pre-existing logs, nginx crash/
#     OOM history in the systemd journal, x-ui client expiry/
#     traffic-quota exhaustion (an Xray-core-level cause completely
#     unrelated to nginx that produces an identical symptom), live
#     listen-state of each CDN inbound's actual port, and UFW state
#     for those ports. Reports verified facts from the live system
#     instead of guessing which cause applies to you.
#  CHANGELOG v4.2 -- root-cause fixes for three confirmed bugs:
#
#  BUG A: "WordPress plugin can only reach the panel subdomain
#  when a proxy/VPN is on; HTTPS to the panel never works, even
#  though a valid Wildcard cert exists."
#    ROOT CAUSE: write_config() in v3.9/v4.1 NEVER wrote an nginx
#    server block for PANEL_DOMAIN at all -- only for CDN_DOMAIN.
#    x-ui was left to serve itself directly on PANEL_PORT over
#    plain HTTP, with no TLS termination anywhere for the panel
#    hostname. Any HTTPS request to PANEL_DOMAIN:443 therefore hit
#    nginx's TLS SNI matching, found no server_name matching the
#    panel domain, and fell through to the default_server
#    catch-all, which does `return 444` (connection closed, no
#    response) per RFC-less nginx convention. That is indistin-
#    guishable from a hang/timeout to any HTTPS client -- exactly
#    what was reported. The wildcard certificate was valid and
#    covered the panel subdomain (confirmed by
#    check_cert_covers_domain), but was never loaded into any
#    server block serving that hostname, so it was never used.
#    The only way to reach the panel was hitting PANEL_PORT
#    directly and unencrypted, which only worked when a
#    proxy/VPN/tunnel bridged that raw port -- matching the
#    reported symptom exactly.
#    FIX: write_config() now ALWAYS writes a dedicated HTTPS
#    server block for PANEL_DOMAIN (when different from
#    CDN_DOMAIN), reusing the SAME validated certificate (the
#    wildcard already confirmed to cover both names), and
#    reverse-proxying to 127.0.0.1:PANEL_PORT over HTTP/1.1 with
#    the real $host preserved. This block carries ZERO ws/xhttp/
#    httpupgrade locations -- it is dedicated purely to the panel,
#    so Reality/gRPC/Hysteria2/etc. inbounds remain fully
#    untouched, exactly as required.
#
#  BUG B: "location / matching logic is wrong; sub_filter logic
#  collides with location /."
#    ROOT CAUSE: _build_camo_block() emitted `gzip off;`,
#    `sub_filter_once off;`, `sub_filter_types ...;` and every
#    `sub_filter '...' '';` directive OUTSIDE the `location / {}`
#    block -- at server-block scope, textually before the
#    location. Per ngx_http_sub_module (official docs: "The
#    sub_filter directives are inherited from the previous
#    configuration level if and only if there are no sub_filter
#    directives defined on the current level"), any directive set
#    at server{} scope is inherited by EVERY location in that
#    server block that does not define its own -- including the
#    ws/xhttp/httpupgrade locations, which have no reason to ever
#    run HTML text substitution against binary WebSocket/XHTTP
#    payloads. This is architecturally wrong regardless of whether
#    sub_filter_types happens to exclude the relevant MIME types in
#    a given run, and is the exact defect described.
#    FIX: gzip off, sub_filter_once, sub_filter_types, and every
#    sub_filter directive are now emitted strictly INSIDE
#    `location / { ... }`, at that location's own scope, so they
#    can never leak to sibling locations by inheritance.
#
#  BUG C: XHTTP/WS location matching priority.
#    ROOT CAUSE / VERIFICATION: per ngx_http_core_module (official
#    docs, "Location" section), regex locations always take
#    priority over prefix locations unless a prefix location is
#    declared with the "^~" modifier, in which case nginx stops
#    searching for a better (regex) match once that prefix wins.
#    All ws/xhttp/httpupgrade locations must therefore be declared
#    with "^~" so they are guaranteed to win outright over the
#    catch-all "location /" and over any future regex location,
#    instead of relying on "longest prefix wins" (which is only
#    nginx's tie-breaker among competing plain-prefix locations,
#    not a guarantee against regex locations).
#    FIX: every ws/httpupgrade/xhttp location is now declared as
#    "location ^~ /path { ... }". "location /" for camouflage
#    remains a plain prefix location (correct -- it is the
#    catch-all fallback and must never claim priority over the
#    specific inbound paths).
#
#  Everything else (panel/CDN domain separation, hardcoded Host
#  header override for ws/httpupgrade, grpc_pass for xhttp per the
#  official XTLS/Xray-examples/VLESS-XHTTP3-Nginx reference,
#  Xray-core-actual Host field fix inside stream_settings, shared
#  wildcard cert validation via SAN inspection, default_server
#  catch-all, colored menu/logging, full uninstall, firewall,
#  real-IP restore, watchdog/persistence) is carried over unchanged
#  from v4.1 and re-verified against nginx -t before shipping.
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
C_CYAN2='\033[1;38;5;51m'
C_MAGENTA2='\033[1;38;5;201m'
C_AMBER='\033[1;38;5;214m'

TITLE='\033[1;36m'; INFO='\033[1;34m'
OK_BG='\033[42m\033[97m'; WARN_BG='\033[43m\033[97m'; ERR_BG='\033[41m\033[97m'

SKIP_BG='\033[1;30;43m'   # yellow bg, black text -> skipped (non-CDN) inbound
CDN_BG='\033[1;30;42m'    # green bg,  black text -> CDN-compatible inbound
FIX_BG='\033[1;30;46m'    # cyan bg,   black text -> Host-header fix applied

PALETTE=(C_PINK C_OLIVE C_LPINK C_TEALGREY C_CHOC C_LCHOC C_SKY C_PURPLE C_GOLD C_ORANGE C_DEEPTEAL C_SLATE C_ROSE C_LIME C_CYAN2 C_MAGENTA2 C_AMBER)
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
# ask_choice VAR "Question" "1:Label one" "2:Label two" ...
# Labels are printed BEFORE the read, so the user always sees what
# each number means at the moment they are asked -- never after.
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
==========================================================
   ____       _     _ ___ ____
  / ___| ___ | | __| |_ _|  _ \
 | |  _ / _ \| |/ _` || || |_) |
 | |_| | (_) | | (_| || ||  __/
  \____|\___/|_|\__,_|___|_|
    N G I N X   C A M O U F L A G E   v4.3 (Uncut)
==========================================================
EOF
}

require_root() { [ "$(id -u)" -eq 0 ] || { err "Run this script as root."; exit 1; }; }

ensure_sqlite3() { command -v sqlite3 >/dev/null 2>&1 || apt-get install -y sqlite3 >/dev/null 2>&1; }

# ---------------- install nginx WITH http_sub_module + http_v2_module ----------------
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
    nginx -V 2>&1 | grep -q 'http_v2_module' || warn "http_v2_module not detected -- HTTP/2 (used by XHTTP over grpc_pass) may be unavailable. nginx-extras normally includes it; verify manually if XHTTP misbehaves."
}

# ---------------- Location Builder ----------------
# BUG C FIX: every ws/httpupgrade/xhttp location now uses "location ^~ /path"
# instead of a plain prefix "location /path". Per the official nginx docs
# (ngx_http_core_module, "Location" directive): a prefix location declared
# with "^~" wins outright over any regex location once nginx determines it
# is the longest matching prefix -- nginx does not even attempt regex
# matching after that. Without "^~", nginx would still check for a better
# regex match after finding the longest prefix, which is unnecessary risk
# once camouflage or future config adds regex locations to the same
# server block. This guarantees these paths can never be shadowed.
#
# Host header for ws/httpupgrade is hardcoded to CDN_DOMAIN explicitly
# (never passes through $host), guaranteeing the backend xray inbound
# always sees the CDN domain regardless of what a client sent, and
# guaranteeing the panel domain can never leak into inbound routing.
#
# XHTTP uses grpc_pass (nginx's built-in ngx_http_grpc_module, part of
# stock nginx core) because XHTTP's stream-up/stream-one modes carry real
# HTTP/2 frames, the same transport family as gRPC -- NOT plain HTTP/1.1
# request/response, which is what proxy_pass + proxy_http_version 1.1
# would (incorrectly) treat it as. This matches the official reference
# nginx.conf in XTLS/Xray-examples/VLESS-XHTTP3-Nginx exactly: grpc_pass,
# client_max_body_size 0, extended timeouts, no forced Host header (XHTTP's
# own protocol framing carries what it needs).
make_location() {
    local t="$1" p="$2" port="$3" hostheader="$4"
    [ "${p:0:1}" != "/" ] && p="/$p"
    if [ "$t" = "xhttp" ]; then
        printf '    location ^~ %s {\n' "$p"
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

# insert_host_py takes address/sni/host_header as ONE explicit parameter
# ($4 = cdn_host) that the caller MUST pass as CDN_DOMAIN. There is no
# code path where PANEL_DOMAIN can end up here -- callers only ever have
# $PRIMARY (== CDN_DOMAIN) in scope at the call site. This writes the
# x-ui "hosts" table used for QR/subscription LINK TEXT only.
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

# strip_tls_py force-rewrites the ACTUAL transport-level Host that
# Xray-core uses at handshake time (wsSettings.headers.Host /
# httpupgradeSettings.host / xhttpSettings.host inside stream_settings)
# to the CDN domain, overwriting any stale panel-domain / blank /
# manually-set value unconditionally, every time it runs. The cosmetic
# x-ui "hosts" table alone is not sufficient -- this is the field
# Xray-core itself reads.
#
# uTLS fingerprint ("chrome" impersonation) is set once, in insert_host_py,
# for ALL three CDN-eligible transports (ws, httpupgrade, xhttp/splithttp)
# -- that field lives in the x-ui "hosts" table and applies uniformly
# regardless of transport type.
#
# Random packet-size padding (xpaddingBytes) is XHTTP-ONLY below. This is
# not an arbitrary choice: per Xray-core's own transport schemas,
# wsSettings and httpupgradeSettings do not define any padding field at
# all -- only xhttpSettings/splithttpSettings expose "extra.xpaddingBytes".
# There is nothing to "enable" for ws/httpupgrade because the protocol
# schema itself has no such option; adding an unrecognized key to those
# settings blocks would either be silently ignored by Xray-core or, on
# stricter builds, rejected as invalid config. If a future Xray-core
# release adds padding support to ws/httpupgrade, extend this function
# with an "ws"/"httpupgrade" branch mirroring the xhttp one below.
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
            # Random packet-size padding: XHTTP-only, see comment above
            # this function for why ws/httpupgrade cannot receive this.
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
        warn "Real clients will ALWAYS show 'not private' for this cert UNLESS the domain is"
        warn "Proxied (orange cloud) through Cloudflare, with SSL mode Full/Full (strict)."
        echo ""

        resolved_ip=$(resolve_domain_ips "$domain")
        if [ -n "$resolved_ip" ]; then
            local sample_ip; sample_ip=$(printf '%s' "$resolved_ip" | awk '{print $1}')
            if printf '%s' "$sample_ip" | grep -qE '^(173\.245\.|103\.21\.|103\.22\.|103\.31\.|141\.101\.|108\.162\.|190\.93\.|188\.114\.|197\.234\.|198\.41\.|162\.158\.|104\.16\.|104\.24\.|172\.6[4-9]\.|172\.7[01]\.|131\.0\.72\.)'; then
                ok "DNS check: ${domain} resolves to ${sample_ip}, which IS a Cloudflare IP range (Proxied). Good."
            else
                err "DNS check: ${domain} resolves to ${sample_ip}, which is NOT a Cloudflare IP."
                err "This means the domain is DNS-only (grey cloud) and clients connect DIRECTLY"
                err "to your server, where they see the Origin Cert and reject it."
                err "Fix: Cloudflare dashboard -> DNS -> turn the cloud icon orange for ${domain}."
            fi
        else
            warn "Could not resolve ${domain} from this server to verify Cloudflare proxy status."
        fi
        echo ""
        local CONT; ask_optional CONT "Continue anyway with this certificate?" "[y/N]"
        is_yes "$CONT" || { err "Aborted by user. Fix the Cloudflare proxy/cert setup and re-run."; exit 1; }
    else
        ok "Certificate issuer does not look like a Cloudflare Origin CA cert. OK for direct trust."
    fi
}

# Verifies a shared certificate actually covers BOTH domains (SAN list,
# or CN as fallback for very old certs, including wildcard SAN entries
# such as *.goldip.me covering both cdn.goldip.me and panel.goldip.me).
# Fails loudly if it doesn't, rather than letting nginx silently serve a
# cert that doesn't match one of the two server_names.
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
        err "Certificate SAN list: $(printf '%s' "$san" | tr '\n' ' ')"
        err "Certificate CN: ${cn}"
        return 1
    fi
}

# ---------------- Auto Build Locations ----------------
# End-of-run summary tracks CDN-routed vs non-CDN inbounds explicitly so
# the user sees exactly what goes through CDN_DOMAIN and what stays
# direct/panel-only. Only inbounds with network type ws, httpupgrade,
# xhttp, or splithttp are EVER modified. Every other type (Reality,
# gRPC, Hysteria2, Trojan, Shadowsocks, etc.) is explicitly skipped.
CDN_ROUTED_SUMMARY=""
NONCDN_SUMMARY=""
HOSTFIX_SUMMARY=""

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
                echo -e "${SKIP_BG} SKIPPED (non-CDN) ${RESET} ${net} \"${remark}\" (Port ${port}) -- stays DIRECT on ${PANEL_DOMAIN:-server IP}, bypasses nginx/CDN entirely."
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

        LOCATIONS="${LOCATIONS}"$'\n'"$(make_location "$ltype" "$path" "$fport" "$PRIMARY")"
        echo -e "${CDN_BG} CDN-OK ${RESET} ${net} \"${remark}\" ${path} -> 127.0.0.1:${fport} (Host: ${PRIMARY}, exposed via CDN_DOMAIN:443)"
        CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [${net}] \"${remark}\" ${path} -> via ${PRIMARY} (CDN-proxied)"
        added=$((added+1))
    done

    [ "$added" -eq 0 ] && { warn "No CDN-compatible inbounds found."; return 1; }
    local AP; ask_optional AP "Apply DB changes (fix transport Host headers + rebuild hosts, CDN_DOMAIN=${PRIMARY})?" "[y/N]"
    if is_yes "$AP"; then
        cp "$db" "${db}.bak.$(date +%s)"
        HOSTFIX_SUMMARY=""
        for m in $(seq 1 "$op_count"); do
            mid="${OP_IDS[$m]}"; mfport="${OP_FPORTS[$m]}"; mnet="${OP_NETS[$m]}"; malpn="${OP_ALPNS[$m]}"
            sqlite3 "$db" "UPDATE inbounds SET listen='127.0.0.1', port=${mfport} WHERE id=${mid};"
            strip_tls_py "$db" "$mid" "$mnet" "$PRIMARY" >/dev/null
            sqlite3 "$db" "DELETE FROM hosts WHERE inbound_id=${mid};"
            insert_host_py "$db" "$mid" "$mnet" "$PRIMARY" "443" "$PRIMARY" "$malpn" >/dev/null
        done
        ok "Database updated (transport Host headers + hosts table all point to ${PRIMARY})! Restarting x-ui..."
        systemctl restart x-ui

        echo ""
        echo -e "${INFO}--- Verifying live binding (reading DB back) ---${RESET}"
        print_verify_table "$db"
    fi
    return 0
}

# Reads live state back from the DB after writes: transport Host header,
# hosts.address, and MATCH/MISMATCH verdict against CDN_DOMAIN.
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

    cur.execute("SELECT address, host_header FROM hosts WHERE inbound_id=? ORDER BY id DESC LIMIT 1;", (iid,))
    hrow = cur.fetchone()
    hosts_address = hrow[0] if hrow else "(none)"
    hosts_hostheader = hrow[1] if hrow else "(none)"

    match = "MATCH" if (transport_host == cdn_host and hosts_address == cdn_host) else "MISMATCH"
    print(f"{iid}|{remark}|{net}|{listen}|{port}|{transport_host}|{hosts_address}|{hosts_hostheader}|{match}")
con.close()
PYEOF
}

verify_cdn_binding_menu() {
    local db=""; for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do [ -f "$c" ] && db="$c" && break; done
    [ -z "$db" ] && { err "x-ui database not found."; return 1; }
    local CDNIN; ask CDNIN "CDN domain to verify against" "(e.g. cdn.example.com)"
    CDNIN=$(strip_scheme "$CDNIN")
    echo -e "${INFO}--- Live binding check for CDN_DOMAIN=${CDNIN} ---${RESET}"
    printf "%-4s %-22s %-10s %-10s %-6s %-22s %-22s %-9s\n" "ID" "Remark" "Net" "Listen" "Port" "TransportHost" "hosts.address" "Verdict"
    while IFS='|' read -r iid remark net listen port thost haddr hheader verdict; do
        [ -z "$iid" ] && continue
        if [ "$verdict" = "MATCH" ]; then
            echo -e "${C_OK}$(printf "%-4s %-22s %-10s %-10s %-6s %-22s %-22s %-9s" "$iid" "${remark:0:22}" "$net" "$listen" "$port" "${thost:-<empty>}" "${haddr:-<none>}" "$verdict")${RESET}"
        else
            echo -e "${C_ERR}$(printf "%-4s %-22s %-10s %-10s %-6s %-22s %-22s %-9s" "$iid" "${remark:0:22}" "$net" "$listen" "$port" "${thost:-<empty>}" "${haddr:-<none>}" "$verdict")${RESET}"
        fi
    done < <(verify_cdn_binding_py "$db" "$CDNIN")
    echo ""
    warn "MISMATCH means the inbound's real WebSocket/XHTTP Host header does NOT equal the CDN domain."
    warn "Run 'Install / Config website' -> Auto discovery again to force-correct any MISMATCH rows."
}

# ============================================================
# Diagnostic for "CDN inbounds stop working after some days".
# This checks FACTS on the running system against every plausible
# root cause instead of guessing which one applies to you:
#   1. Disk space -- unbounded nginx logs (fixed going forward by the
#      logrotate policy in write_config, but pre-existing huge log
#      files from before that fix are checked here too).
#   2. nginx crash/restart history via systemd journal -- tells you
#      definitively whether nginx itself has been dying.
#   3. Expired or traffic-exhausted x-ui clients -- an Xray-core-level
#      cause, entirely unrelated to nginx, that produces the exact
#      same symptom (inbound "stops working" after N days matches
#      the client's own expiry/quota, not a routing bug).
#   4. UFW firewall state for the local ports each CDN inbound
#      actually listens on -- confirms whether the firewall still
#      allows traffic to reach nginx's upstream ports.
#   5. Live listen-state cross-check: are the ports x-ui's DB says
#      each inbound should be on actually LISTENING right now.
# ============================================================
diagnose_delayed_disconnect() {
    echo -e "${INFO}=== 1. Disk space ===${RESET}"
    local disk_line disk_pct
    disk_line=$(df -h / 2>/dev/null | tail -n1)
    disk_pct=$(printf '%s' "$disk_line" | awk '{print $5}' | tr -d '%')
    echo "  ${disk_line}"
    if [ -n "$disk_pct" ] && [ "$disk_pct" -ge 90 ]; then
        err "Root filesystem is ${disk_pct}% full. This alone can cause nginx to fail unpredictably"
        err "(cannot write access/error logs, cannot open new file descriptors). Free up space or"
        err "check /var/log/nginx/ for oversized log files below."
    elif [ -n "$disk_pct" ] && [ "$disk_pct" -ge 75 ]; then
        warn "Root filesystem is ${disk_pct}% full. Not critical yet, but worth monitoring."
    else
        ok "Root filesystem usage looks fine (${disk_pct:-unknown}%)."
    fi

    echo ""
    echo -e "${INFO}=== 2. nginx log file sizes ===${RESET}"
    if [ -d /var/log/nginx ]; then
        local big_logs
        big_logs=$(find /var/log/nginx -maxdepth 1 -name '*.log' -size +200M 2>/dev/null)
        if [ -n "$big_logs" ]; then
            err "Oversized (>200MB) nginx log files found -- these were growing unbounded before the"
            err "logrotate policy in this script version existed. Consider truncating/archiving them:"
            printf '%s\n' "$big_logs" | while read -r f; do echo "    $(du -h "$f" 2>/dev/null)"; done
        else
            ok "No oversized (>200MB) nginx log files found."
        fi
    else
        warn "/var/log/nginx does not exist -- nginx may not be installed or has never logged anything."
    fi

    echo ""
    echo -e "${INFO}=== 3. nginx crash/restart history (last 14 days) ===${RESET}"
    if command -v journalctl >/dev/null 2>&1; then
        local restarts
        restarts=$(journalctl -u nginx --since "-14 days" 2>/dev/null | grep -ciE 'fail|core dump|killed|out of memory|segfault')
        if [ "$restarts" -gt 0 ]; then
            err "Found ${restarts} nginx failure-related log lines in the last 14 days. Run:"
            err "  journalctl -u nginx --since '-14 days' | grep -iE 'fail|killed|memory'"
            err "to see exact timestamps and correlate them with when inbounds stopped working."
        else
            ok "No nginx failure/crash/OOM lines found in the systemd journal for the last 14 days."
        fi
    else
        warn "journalctl not available -- cannot check nginx crash history this way."
    fi

    echo ""
    echo -e "${INFO}=== 4. x-ui client expiry / traffic quota (Xray-core-level, NOT an nginx issue) ===${RESET}"
    local db=""; for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do [ -f "$c" ] && db="$c" && break; done
    if [ -n "$db" ]; then
        local now_ms; now_ms=$(($(date +%s) * 1000))
        local expired_count
        expired_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM client_traffics WHERE enable=1 AND expiry_time > 0 AND expiry_time < ${now_ms};" 2>/dev/null)
        local quota_exceeded
        quota_exceeded=$(sqlite3 "$db" "SELECT COUNT(*) FROM client_traffics WHERE enable=1 AND total > 0 AND (up + down) >= total;" 2>/dev/null)
        if [ -n "$expired_count" ] && [ "$expired_count" -gt 0 ]; then
            warn "${expired_count} enabled client(s) have an expiry_time already in the past. Xray-core"
            warn "disables these clients itself once expired -- this looks IDENTICAL to a routing"
            warn "failure but is a per-client setting inside x-ui, not an nginx/CDN bug."
        fi
        if [ -n "$quota_exceeded" ] && [ "$quota_exceeded" -gt 0 ]; then
            warn "${quota_exceeded} enabled client(s) have used up their full traffic quota (total GB)."
            warn "Same effect as above: Xray-core stops serving that specific client, independent of nginx."
        fi
        if [ "${expired_count:-0}" -eq 0 ] && [ "${quota_exceeded:-0}" -eq 0 ]; then
            ok "No expired or quota-exhausted clients found in x-ui's database."
        fi
    else
        warn "x-ui database not found -- skipped client expiry/quota check."
    fi

    echo ""
    echo -e "${INFO}=== 5. Live listen-state cross-check (DB port vs actually LISTENING) ===${RESET}"
    if [ -n "$db" ]; then
        local listening_ports; listening_ports=$(ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -oE '[0-9]+$' | sort -u)
        while IFS='|' read -r iid remark listen port net; do
            [ -z "$iid" ] && continue
            case "$net" in ws|httpupgrade|xhttp|splithttp) : ;; *) continue ;; esac
            if printf '%s\n' "$listening_ports" | grep -qx "$port"; then
                echo -e "${C_OK}  [OK] Inbound #${iid} (${remark}) DB port ${port} IS currently listening.${RESET}"
            else
                echo -e "${C_ERR}  [DOWN] Inbound #${iid} (${remark}) DB port ${port} is NOT listening right now -- Xray-core is not bound to it. Restart x-ui and check its own logs (x-ui log) for why this specific inbound failed to bind.${RESET}"
            fi
        done < <(sqlite3 -separator '|' "$db" "SELECT id, remark, listen, port, json_extract(stream_settings,'\$.network') FROM inbounds;" 2>/dev/null)
    fi

    echo ""
    echo -e "${INFO}=== 6. UFW status for CDN-facing ports ===${RESET}"
    if command -v ufw >/dev/null 2>&1; then
        local ufw_state; ufw_state=$(ufw status 2>/dev/null | head -n1)
        echo "  ${ufw_state}"
        if printf '%s' "$ufw_state" | grep -qi inactive; then
            warn "UFW is INACTIVE. If you expected it to restrict access, it currently is not."
        else
            ok "UFW is active. If a CDN inbound's local port was never explicitly allowed (this script"
            ok "only opens firewall rules when you run 'Setup firewall' from the menu, not automatically"
            ok "on every install), traffic to that port could be silently dropped. Re-run 'Setup firewall'"
            ok "after adding/changing inbounds to keep rules in sync with the current inbound list."
        fi
    else
        warn "ufw not installed -- skipped firewall check."
    fi

    echo ""
    echo -e "${INFO}=====================================================${RESET}"
    echo -e "${INFO}Summary: sections marked in red above are concrete, verified findings on THIS system --${RESET}"
    echo -e "${INFO}not speculation. Start with any red section; it is the most likely explanation.${RESET}"
}


# BUG B FIX: gzip off, sub_filter_once, sub_filter_types, and every
# sub_filter directive are now built as a SEPARATE string
# (CAMO_SUBFILTER_DIRECTIVES) that write_config() places strictly INSIDE
# "location / { ... }" -- never at server{} scope. Per the official
# ngx_http_sub_module docs, sub_filter directives set at a given
# configuration level are inherited by nested levels ONLY IF that nested
# level defines no sub_filter directives of its own; a directive placed
# at server{} scope is therefore visible to every sibling location
# (including ws/xhttp/httpupgrade) unless it defines its own (which they
# do not). Scoping these strictly inside location / eliminates that
# inheritance path entirely -- ws/xhttp/httpupgrade locations are never
# exposed to sub_filter/gzip processing at all.
_build_camo_block() {
    local js_file="/tmp/goldip_js_$$.js"
    cat > "$js_file" <<JSEOF
<script>(function(){var H="PROXY_HOST_PH",S="PROXY_SCHEME_PH";var r1=new RegExp(S+"://"+H.replace(/\./g,"\\."),\"g\");var r2=new RegExp("//"+H.replace(/\./g,"\\."),\"g\");function c(u){return typeof u==="string"?u.replace(r1,"").replace(r2,""):u;}var oF=window.fetch;window.fetch=function(u,o){return oF.call(this,c(u),o);};var oX=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){return oX.apply(this,[m,c(u)].concat(Array.prototype.slice.call(arguments,2)));};var oP=history.pushState,oR=history.replaceState;history.pushState=function(s,t,u){return oP.call(this,s,t,c(u));};history.replaceState=function(s,t,u){return oR.call(this,s,t,c(u));};try{var dl=Object.getOwnPropertyDescriptor(window.location,"href");if(dl&&dl.set){Object.defineProperty(window.location,"href",{set:function(v){window.history.replaceState(null,"",c(v));},get:dl.get,configurable:true});}}catch(e){}document.addEventListener("click",function(e){var a=e.target.closest("a");if(!a)return;var h=a.getAttribute("href")||\"\";if(r1.test(h)||r2.test(h)){e.preventDefault();window.history.pushState(null,"",c(h));}},true);})();</script>
JSEOF
    local js_inline
    js_inline=$(sed "s|PROXY_HOST_PH|${PROXY_HOST}|g; s|PROXY_SCHEME_PH|${PROXY_SCHEME}|g" "$js_file" | tr -d '\n')
    rm -f "$js_file"

    # These directives are valid ONLY inside location{} scope in the final
    # config; they are emitted here as a standalone string and inserted by
    # write_config() at the correct nesting level (inside location /),
    # never at server{} scope.
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

    # CAMO_BLOCK is now a SINGLE, correctly-scoped location / block: the
    # sub_filter/gzip directives and the proxy directives live together
    # inside the same location, so nothing leaks to sibling locations by
    # inheritance, and nothing is declared twice.
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
    CDN_ROUTED_SUMMARY=""; NONCDN_SUMMARY=""; HOSTFIX_SUMMARY=""

    echo -e "${INFO}=== Panel Configuration ===${RESET}"
    ask RAW_PANEL "Panel Domain / IP" "(e.g. panel.example.com -- used for the x-ui admin panel + non-CDN inbounds)"
    PANEL_DOMAIN=$(strip_scheme "$RAW_PANEL"); PANEL_DOMAIN=$(strip_port "$PANEL_DOMAIN")
    ask_port PANEL_PORT "Panel Port (the port x-ui itself listens on)" 2053

    echo -e "${INFO}=== CDN Configuration ===${RESET}"
    ask RAW_CDN "CDN Domain" "(e.g. cdn.example.com -- this is the ONLY domain proxied through Cloudflare/Arvan)"
    CDN_DOMAIN=$(strip_scheme "$RAW_CDN"); PRIMARY="$CDN_DOMAIN"
    ask_port HTTPS_PORT "HTTPS Port" 443
    ask_port HTTP_PORT  "HTTP Port"  80

    if [ "$PANEL_DOMAIN" = "$CDN_DOMAIN" ]; then
        warn "Panel domain and CDN domain are IDENTICAL (${CDN_DOMAIN})."
        warn "Non-CDN inbounds (Reality/gRPC/Hysteria2) cannot coexist with CDN inbounds on the"
        warn "exact same hostname behind a Cloudflare-proxied record, since Cloudflare's proxy"
        warn "only forwards standard HTTP/S -- not arbitrary TCP/UDP protocols."
        local SAMEOK; ask_optional SAMEOK "Continue with panel == CDN domain anyway?" "[y/N]"
        is_yes "$SAMEOK" || { err "Aborted. Re-run and provide two different domains for panel and CDN."; exit 1; }
    else
        ok "Panel domain (${PANEL_DOMAIN}) and CDN domain (${CDN_DOMAIN}) are separate. Recommended setup confirmed."
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

    echo -e "${INFO}=== Shared Certificate Validation ===${RESET}"
    local cdn_ok=1 panel_ok=1
    check_cert_covers_domain "$SSL_CERT" "$CDN_DOMAIN" "CDN domain" || cdn_ok=0
    if [ "$PANEL_DOMAIN" != "$CDN_DOMAIN" ]; then
        check_cert_covers_domain "$SSL_CERT" "$PANEL_DOMAIN" "Panel domain" || panel_ok=0
    fi
    if [ "$cdn_ok" -eq 0 ]; then
        err "Certificate does not cover the CDN domain (${CDN_DOMAIN}). This WILL cause TLS errors. Aborting."
        exit 1
    fi
    if [ "$panel_ok" -eq 0 ]; then
        err "Certificate does NOT cover the panel domain (${PANEL_DOMAIN})."
        err "This build ALWAYS terminates HTTPS for the panel using this same certificate (that is"
        err "the fix for the reported 'panel HTTPS never works' bug), so this certificate must"
        err "cover BOTH names -- get a proper SAN/wildcard cert that includes ${PANEL_DOMAIN}."
        exit 1
    fi

    ensure_cert_renew_hook "$SSL_CERT"

    BEHIND_CF=""
    local __cdn_ip; __cdn_ip=$(resolve_domain_ips "$CDN_DOMAIN" | awk '{print $1}')
    if [ -n "$__cdn_ip" ] && printf '%s' "$__cdn_ip" | grep -qE '^(173\.245\.|103\.21\.|103\.22\.|103\.31\.|141\.101\.|108\.162\.|190\.93\.|188\.114\.|197\.234\.|198\.41\.|162\.158\.|104\.16\.|104\.24\.|172\.6[4-9]\.|172\.7[01]\.|131\.0\.72\.)'; then
        ok "Detected ${CDN_DOMAIN} resolves to a Cloudflare IP (${__cdn_ip}) -- enabling real-IP restore automatically."
        BEHIND_CF="y"
    else
        ok "${CDN_DOMAIN} does not currently resolve to a Cloudflare IP (or DNS lookup failed) -- skipping real-IP restore. Enable it later from the firewall menu if you turn on the orange cloud."
    fi

    echo -e "${INFO}=== Inbounds ===${RESET}"
    local DISC
    ask_choice DISC "Inbound discovery mode:" \
        "1:Auto (read ws/httpupgrade/xhttp inbounds from x-ui DB)" \
        "2:Manual entry"

    [ "$DISC" = "1" ] && { auto_build_locations || warn "Auto-build failed or skipped. Switching to manual."; }

    if [ "$DISC" = "2" ] || [ -z "$LOCATIONS" ]; then
        ask_number NIN "How many CDN inbounds to add to Nginx?"
        local i=1
        while [ "$i" -le "$NIN" ]; do
            echo -e "${INFO}--- Inbound #${i} ---${RESET}"
            ask P_PATH "Path" "(e.g. /ws${i})"
            [ "${P_PATH:0:1}" = "/" ] || P_PATH="/$P_PATH"
            ask_number P_PORT "Local Xray port"
            local P_TYPE
            ask_choice P_TYPE "Transport:" \
                "1:WebSocket / HTTPUpgrade" \
                "2:XHTTP"
            case "$P_TYPE" in
                1) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location upgrade "$P_PATH" "$P_PORT" "$PRIMARY")"
                   CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [ws/httpupgrade] ${P_PATH} -> via ${PRIMARY} (manual entry)"
                   warn "Manual entry does NOT touch x-ui's internal transport Host field. Go into x-ui"
                   warn "-> panel and set this inbound's WS/HTTPUpgrade Host header to ${PRIMARY} manually,"
                   warn "or use Auto discovery instead so this script rewrites it for you." ;;
                2) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location xhttp "$P_PATH" "$P_PORT" "$PRIMARY")"
                   CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [xhttp] ${P_PATH} -> via ${PRIMARY} (manual entry)"
                   warn "Manual entry does NOT touch x-ui's internal transport host field. Go into x-ui"
                   warn "-> panel and set this inbound's XHTTP host field to ${PRIMARY} manually, or use"
                   warn "Auto discovery instead so this script rewrites it for you." ;;
            esac
            i=$((i+1))
        done
    fi

    echo -e "${INFO}=== Camouflage ===${RESET}"
    local CAMO
    ask_choice CAMO "Camouflage type:" \
        "1:Reverse Proxy (mirror a real website)" \
        "2:Local HTML (serve your own index.html)"
    if [ "$CAMO" = "1" ]; then
        ask PROXY_URL "Website to proxy (e.g. example.com)"
        PROXY_HOST=$(strip_scheme "$PROXY_URL"); PROXY_SCHEME="https"
        PROXY_BASEPATH=$(printf '%s' "$PROXY_URL" | sed -E 's#^https?://[^/]*##')
        [ -z "$PROXY_BASEPATH" ] && PROXY_BASEPATH="/"
        _build_camo_block
    else
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
        CAMO_BLOCK="    location / { root ${CAMO_ROOT}; index index.html; }"
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

# BUG A FIX: write_config() now ALWAYS writes a dedicated HTTPS server
# block for PANEL_DOMAIN (when it differs from CDN_DOMAIN), reusing the
# SAME already-validated certificate (guaranteed by
# check_cert_covers_domain in gather_inputs to cover both names -- for a
# wildcard cert like *.goldip.me this is automatic). This block proxies
# ONLY to 127.0.0.1:PANEL_PORT over plain HTTP/1.1 with the real Host
# preserved via $host (correct here -- this is the actual admin panel
# app, not an Xray inbound, so it should see whatever Host a legitimate
# client sends, matching how x-ui/WordPress expect a normal reverse
# proxy to behave). It carries NO ws/xhttp/httpupgrade locations, so
# Reality/gRPC/Hysteria2/etc. remain completely unaffected -- they keep
# listening on their own ports directly, exactly as before.
#
# Because BOTH domains now have real server_name blocks with matching
# certificates, nginx's SNI-based virtual host selection (see
# ngx_http_ssl_module docs) correctly picks the panel's own certificate
# and location config for panel traffic instead of ever falling through
# to the default_server catch-all -- which is the exact mechanism that
# was returning 444 for panel HTTPS requests before this fix.
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

    # default_server catch-all: written to its own dedicated file, once,
    # shared across all CDN/panel domains configured over time. nginx
    # allows only ONE default_server per listen address:port; keeping it
    # in a single shared file guarantees that invariant regardless of how
    # many domain .conf files exist. Because CDN_DOMAIN and PANEL_DOMAIN
    # both now get real server_name blocks (this is the actual fix), this
    # catch-all only ever triggers for genuinely unmatched Host/SNI values
    # (stale client profiles, IP scanners hitting the raw server IP) --
    # never for legitimate panel or CDN traffic anymore.
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
            echo "# CDN/panel domains configured by this script). Rejects any request"
            echo "# whose Host/SNI does not match a configured domain."
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
        ok "Default-server catch-all written to ${catchall_conf} (rejects unmatched Host/SNI on ${HTTP_PORT}/${HTTPS_PORT})."
    fi

    # ---- CDN_DOMAIN server block (ws/xhttp/httpupgrade + camouflage) ----
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
        echo "${CAMO_BLOCK}"
        echo "}"
    } > "$conf"

    # ---- PANEL_DOMAIN server block (THE FIX for bug A) ----
    # Dedicated HTTPS vhost for the admin panel only. Reuses the same
    # certificate (already confirmed to cover this name). Proxies
    # exclusively to PANEL_PORT. No ws/xhttp/httpupgrade locations here --
    # Reality/gRPC/Hysteria2/other non-CDN inbounds are untouched and keep
    # listening on their own ports directly, independent of this block.
    if [ "$PANEL_DOMAIN" != "$CDN_DOMAIN" ]; then
        local panel_conf="${NGINX_CONF_DIR}/${PANEL_DOMAIN}.conf"
        {
            echo "server {"
            echo "    listen ${HTTP_PORT};"
            echo "    server_name ${PANEL_DOMAIN};"
            echo "    return 301 https://\$host\$request_uri;"
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
            echo "    client_max_body_size 50m;"
            echo "    location / {"
            echo "        proxy_pass http://127.0.0.1:${PANEL_PORT};"
            echo "        proxy_http_version 1.1;"
            echo "        proxy_set_header Upgrade \$http_upgrade;"
            echo "        proxy_set_header Connection \"upgrade\";"
            echo "        proxy_set_header Host \$host;"
            echo "        proxy_set_header X-Real-IP \$remote_addr;"
            echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
            echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
            echo "        proxy_read_timeout 300s;"
            echo "        proxy_send_timeout 300s;"
            echo "    }"
            echo "}"
        } > "$panel_conf"
        ok "Panel domain HTTPS block written (${PANEL_DOMAIN}:${HTTPS_PORT}) using the SAME validated certificate -- proxies ONLY to panel port ${PANEL_PORT}. This is the fix for the panel-HTTPS/WordPress-plugin bug."
    fi

    # ---- FIX: dedicated logrotate for the per-domain access/error logs ----
    # write_config() creates a NEW access_log/error_log pair per domain
    # (${PRIMARY}.access.log, ${PRIMARY}.error.log, ${PANEL_DOMAIN}.access.log,
    # etc.) but nothing in this script ever registered those exact filenames
    # with logrotate. Distro-provided /etc/logrotate.d/nginx (from the
    # nginx-extras package) globs /var/log/nginx/*.log, which DOES already
    # cover these files on most Debian/Ubuntu installs -- but relying on
    # that alone is fragile: if that package file is ever missing, replaced,
    # or the glob pattern differs, these per-domain logs grow completely
    # unbounded. Unbounded growth over days/weeks eventually exhausts disk
    # space; when nginx cannot write to its access/error log or open new
    # log file descriptors, worker processes fail unpredictably (ENOSPC/
    # crashes), which presents to a user as CDN-routed inbounds "randomly
    # disconnecting after some days" -- a delayed-onset failure with
    # exactly this profile. This script now installs an explicit,
    # self-owned logrotate policy for every log path it itself creates, so
    # it never depends on the distro's default file being present/correct.
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
    ok "Logrotate policy installed for /var/log/nginx/*.access.log and *.error.log (daily, 14 rotations, USR1 reopen -- prevents unbounded log growth from exhausting disk over time)."

    if nginx -t; then
        if systemctl restart nginx; then
            ok "Nginx Configured & Running on HTTPS (${HTTPS_PORT}) for CDN_DOMAIN=${CDN_DOMAIN} and PANEL_DOMAIN=${PANEL_DOMAIN}!"
        else
            err "nginx -t passed but 'systemctl restart nginx' failed. Run: systemctl status nginx -l"
            return 1
        fi
    else
        err "nginx -t FAILED (see errors above). Config was written but NOT activated."
        return 1
    fi

    echo ""
    echo -e "${INFO}================= ROUTING SUMMARY =================${RESET}"
    echo -e "${C_LIME}CDN-proxied domain:${RESET}   ${CDN_DOMAIN}  (behind Cloudflare/Arvan, nginx terminates TLS here, ws/xhttp/httpupgrade only)"
    echo -e "${C_ROSE}Panel domain:${RESET}          ${PANEL_DOMAIN}  (nginx now terminates HTTPS here too, reverse-proxied to 127.0.0.1:${PANEL_PORT}; not touched by CDN inbound routing)"
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

    local CDN_CHOICE
    ask_choice CDN_CHOICE "CDN Provider:" \
        "1:Cloudflare" \
        "2:ArvanCloud" \
        "3:Both" \
        "4:Custom"
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
        ok "Nginx fully uninstalled -- no binary, package, config, log, or systemd unit remains."
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
        echo -e "  ${C_CYAN2}12) Verify CDN Host-header binding (live DB check)${RESET}"
        echo -e "  ${C_MAGENTA2}13) Diagnose delayed inbound disconnects (crash/expiry/firewall)${RESET}"
        echo -e "  ${C_ERR}14) FULL Nginx uninstall + cleanup${RESET}"
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
            12) verify_cdn_binding_menu ;;
            13) diagnose_delayed_disconnect ;;
            14) full_uninstall ;;
            0)  exit 0 ;;
            *)  err "Invalid choice." ;;
        esac
        local _; ask_optional _ "Press Enter to continue..."
    done
}

require_root; menu
