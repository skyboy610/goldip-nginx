#!/bin/bash
# ============================================================
#  GoldIP Nginx Camouflage Installer & Manager  v4.4 (Uncut)
#  CHANGELOG v4.4 (fixes the REAL cause of "all inbounds show CDN
#  domain, including Hysteria2/Reality" reported after v4.0-4.3):
#   - ROOT CAUSE: earlier versions offered to set x-ui's GLOBAL
#     "subDomain" setting to CDN_DOMAIN. subDomain is a single
#     panel-wide value used by x-ui to build the subscription LINK
#     TEXT for every inbound — Reality, Hysteria2, gRPC included.
#     Setting it to CDN_DOMAIN made the subscription page display
#     CDN_DOMAIN next to every inbound's config, even ones this
#     script never touches and that are not behind nginx/Cloudflare
#     at all. Their real stream_settings, listen address, and port
#     were correctly left alone the whole time (which is why the
#     panel's own inbound-edit view looked correct) — only the
#     subscription TEXT was wrong.
#   - FIX: this script no longer touches subDomain/subEnable/subPort
#     under any circumstances. check_subscription_domain() now only
#     warns; it never writes to the settings table.
#   - NEW: menu option "Repair: clear global subDomain" — a one-time
#     cleanup for anyone who already had subDomain set to CDN_DOMAIN
#     by an older run of this script. Clears it back to empty and
#     restarts x-ui. Does not touch stream_settings or the hosts
#     table for any inbound.
#  CHANGELOG v4.3:
#   - REMOVED: the manual "Behind Cloudflare CDN?" question. You already
#     provide the CDN domain and a Cloudflare-issued cert, so asking
#     again was redundant. Now detected automatically via DNS: if
#     CDN_DOMAIN resolves to a known Cloudflare IP range, real-IP
#     restore is enabled with zero prompts. If not (Arvan, or orange
#     cloud not yet on), it's skipped silently and can be turned on
#     later from the firewall menu.
#  CHANGELOG v4.2:
#   - REMOVED: the redundant "will the panel domain be proxied?"
#     question. It added an extra prompt for no protective benefit —
#     this script never routes CDN inbound traffic through the panel
#     domain regardless of its Cloudflare proxy setting, so asking
#     about it bought nothing. Flow is now: panel domain -> CDN
#     domain -> straight into cert/inbound setup.
#   - FIXED: XHTTP nginx location was missing proxy_buffering off /
#     proxy_request_buffering off. XHTTP's stream-up/stream-one modes
#     are long-lived chunked transfers; nginx's default buffering
#     silently breaks them (stalls, resets, timeouts) after the TLS
#     patch moved XHTTP behind nginx. Also switched to "location ^~"
#     so XHTTP's per-chunk sub-paths can never be shadowed by a regex
#     location in the same server block, added Connection "" (needed
#     for proper upstream keep-alive under proxy_http_version 1.1),
#     disabled proxy_cache, and removed the incorrect hardcoded
#     Sec-Fetch-Mode override (clients set this themselves; forcing
#     it can conflict with what real client fingerprints send).
#  CHANGELOG v4.1 (on top of v4.0's backend Host-header fix):
#   - NEW: nginx now also writes a dedicated TLS server block for
#     PANEL_DOMAIN, using the SAME shared certificate as CDN_DOMAIN
#     (your cert covers all subdomains, per your setup). This block
#     ONLY proxies to the x-ui panel port — it contains ZERO ws/
#     xhttp/httpupgrade locations. Reality, gRPC, and every other
#     non-CDN inbound remain 100% untouched, still listening
#     directly on their own ports exactly as before.
#   - CONFIRMED: only inbounds with network type ws, httpupgrade,
#     xhttp, or splithttp are ever modified (listen/port rewritten
#     to 127.0.0.1:<local>, security stripped, transport Host header
#     forced to CDN_DOMAIN, hosts-table rebuilt). Every other
#     inbound type is explicitly skipped and reported as such.
#  CHANGELOG v4.0 (fixes the "looks like CDN but backend still
#  talks to panel domain" bug from v3.9):
#   - ROOT CAUSE FOUND: v3.9 only wrote CDN_DOMAIN into the x-ui
#     "hosts" table (used for QR/subscription links). It NEVER
#     touched the actual stream_settings.wsSettings.headers.Host
#     or stream_settings.xhttpSettings.host fields inside the
#     inbound itself. Those fields are what Xray ACTUALLY uses
#     for the real WebSocket/XHTTP handshake at runtime. If they
#     were empty or still set to the panel domain, the backend
#     connection negotiated with a Host header that did not match
#     CDN_DOMAIN — while the link/QR shown to the user still said
#     CDN_DOMAIN. Result: looks CDN, behaves like direct-to-panel.
#   - FIX: strip_tls_py now ALSO force-writes
#     wsSettings.headers.Host / xhttpSettings.host (and
#     httpupgradeSettings.host where applicable) to CDN_DOMAIN,
#     for every CDN-compatible inbound touched by this script.
#     This is done inside the SAME python transaction that already
#     rewrites stream_settings, so there is no window where the
#     two can drift apart again.
#   - FIX: subscription server settings (subDomain / subPort) are
#     now checked. If subDomain is empty or equals PANEL_DOMAIN
#     while inbounds are CDN-routed, you get an explicit warning
#     (never silently "fixed" — subscription domain is your choice,
#     but you must know it's wrong) with the option to set it to
#     CDN_DOMAIN in one step.
#   - NEW: verify_cdn_binding — a dedicated menu action + automatic
#     post-apply check that re-reads the DB and prints, per inbound:
#     the live listen/port, hosts.address, wsSettings/xhttpSettings
#     Host, and whether they ALL agree with CDN_DOMAIN. No more
#     guessing — you see the real bound values, not just intent.
#   - NEW: same fix applied to ANY inbound the auto-builder touches,
#     including ones added later — every time you run "Install /
#     Config website" and choose Auto discovery, the Host-header
#     consistency check + fix runs again for all CDN inbounds.
#   - kept from v3.9: explicit panel/CDN domain separation, hardcoded
#     nginx Host header (never $host passthrough), shared-cert SAN
#     validation, full colored menu, colored logs, robust uninstall,
#     Cloudflare Origin-CA diagnosis, nginx-extras auto-install,
#     nginx -t / restart failures never swallowed, http2 syntax
#     version-aware.
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

TITLE='\033[1;36m'; INFO='\033[1;34m'
OK_BG='\033[42m\033[97m'; WARN_BG='\033[43m\033[97m'; ERR_BG='\033[41m\033[97m'

SKIP_BG='\033[1;30;43m'   # yellow bg, black text -> skipped (non-CDN) inbound
CDN_BG='\033[1;30;42m'    # green bg,  black text -> CDN-compatible inbound
FIX_BG='\033[1;30;46m'    # cyan bg,   black text -> Host-header fix applied

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
fix()  { echo -e "${FIX_BG} FIXED ${RESET} ${C_CYAN2}$1${RESET}"; }

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
    # Usage: ask_choice VAR "Question" "1:Label one" "2:Label two" ...
    # Prints every numbered label BEFORE reading input — fixes the old bug
    # where labels were echoed by the caller AFTER ask_choice already
    # blocked on read, so the user saw bare numbers with no explanation.
    local __var="$1" __q="$2"; shift 2
    local -a __labels=("$@")
    local __valid="" __ans __o __num __text
    for __o in "${__labels[@]}"; do
        __num="${__o%%:*}"
        __valid="${__valid:+${__valid}|}${__num}"
    done
    while true; do
        echo -e "${INFO}${__q}${RESET}"
        for __o in "${__labels[@]}"; do
            __num="${__o%%:*}"; __text="${__o#*:}"
            nextcolor
            echo -e "  ${CURCOLOR}${__num}) ${__text}${RESET}"
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
    N G I N X   C A M O U F L A G E   v4.4 (Uncut)
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
# every location hardcodes the Host header to CDN_DOMAIN explicitly
# (never passes through $host), guaranteeing the backend xray inbound
# always sees the CDN domain regardless of what a client sent, and
# guaranteeing the panel domain can never leak into inbound routing.
#
# XHTTP FIX: XHTTP (Xray's HTTP/2-3-style multi-mode transport: stream-up,
# stream-one, packet-up) breaks behind a naive nginx proxy_pass for two
# concrete reasons that were missing before:
#   1. nginx buffers full request/response bodies by default. XHTTP's
#      stream-up/stream-one modes are long-lived, chunked, and
#      bidirectional-ish — buffering causes stalls, timeouts, or outright
#      connection resets, especially for anything but tiny transfers.
#      Fix: proxy_request_buffering off + proxy_buffering off.
#   2. "location /path {" only matches the exact literal /path prefix
#      boundary the way nginx interprets it, but XHTTP clients hit
#      sub-paths like /path/<session-id> for each stream chunk. A plain
#      prefix location technically still matches those in nginx (prefix
#      locations are substring-prefix, not exact), so this part was not
#      actually broken — but "location ^~ /path" makes the intent explicit
#      and stops any regex location elsewhere in the config from taking
#      priority over it, which matters once camouflage sub_filter regex
#      locations exist in the same server block.
make_location() {
    local t="$1" p="$2" port="$3" hostheader="$4"
    [ "${p:0:1}" != "/" ] && p="/$p"
    if [ "$t" = "xhttp" ]; then
        printf '    location ^~ %s {\n' "$p"
        printf '        proxy_pass http://127.0.0.1:%s;\n' "$port"
        printf '        proxy_http_version 1.1;\n'
        printf '        proxy_set_header Host %s;\n' "$hostheader"
        printf '        proxy_set_header X-Real-IP $remote_addr;\n'
        printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
        printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
        printf '        proxy_set_header Connection "";\n'
        printf '        proxy_request_buffering off;\n'
        printf '        proxy_buffering off;\n'
        printf '        proxy_cache off;\n'
        printf '        client_max_body_size 0;\n'
        printf '        proxy_read_timeout 600s;\n'
        printf '        proxy_send_timeout 600s;\n'
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
        printf '        proxy_buffering off;\n'
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
# code path where PANEL_DOMAIN can end up here — callers only ever have
# $PRIMARY (== CDN_DOMAIN) in scope at the call site (see auto_build_locations).
# This writes the x-ui "hosts" table used for QR/subscription LINK TEXT only.
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

# ============================================================
# THE ACTUAL FIX (v4.0): strip_tls_py used to only flip security
# to "none" and strip tls/reality blocks. It NEVER touched the
# transport-level Host header that Xray uses for the REAL
# WebSocket/XHTTP/HTTPUpgrade handshake — that field lives at
# stream_settings.wsSettings.headers.Host (or .xhttpSettings.host,
# or .httpupgradeSettings.host depending on transport). If that
# field was blank or still set to the old panel domain, the
# backend connection between nginx and Xray (and, more importantly,
# what Xray validates the request against) used the WRONG host —
# even though the "hosts" table (cosmetic, for QR/links) correctly
# showed CDN_DOMAIN. This function now force-writes the transport
# Host header to cdn_host in the SAME atomic write as the TLS strip,
# for ws, xhttp/splithttp, and httpupgrade transports.
# ============================================================
strip_tls_py() {
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import sqlite3, json, sys
try:
    con = sqlite3.connect(sys.argv[1]); cur = con.cursor()
    inb_id = int(sys.argv[2]); net = sys.argv[3]; cdn_host = sys.argv[4]

    cur.execute("SELECT stream_settings FROM inbounds WHERE id=?", (inb_id,))
    row = cur.fetchone()
    changed_host = False
    if row and row[0]:
        ss = json.loads(row[0])
        ss["security"] = "none"
        for k in ("tlsSettings", "realitySettings", "externalProxy", "externalProxySettings"):
            ss.pop(k, None)

        if net in ("xhttp", "splithttp"):
            s_key = net + "Settings"
            if s_key not in ss or not isinstance(ss.get(s_key), dict):
                ss[s_key] = {}
            if "extra" not in ss[s_key]:
                ss[s_key]["extra"] = {}
            ss[s_key]["extra"]["xpaddingBytes"] = "100-1000"
            # THE FIX: force the transport-level host to CDN_DOMAIN.
            # x-ui/Xray reads this field for the real handshake, not
            # the cosmetic "hosts" table.
            if ss[s_key].get("host") != cdn_host:
                ss[s_key]["host"] = cdn_host
                changed_host = True

        elif net == "ws":
            if "wsSettings" not in ss or not isinstance(ss.get("wsSettings"), dict):
                ss["wsSettings"] = {}
            if "headers" not in ss["wsSettings"] or not isinstance(ss["wsSettings"].get("headers"), dict):
                ss["wsSettings"]["headers"] = {}
            if ss["wsSettings"]["headers"].get("Host") != cdn_host:
                ss["wsSettings"]["headers"]["Host"] = cdn_host
                changed_host = True

        elif net == "httpupgrade":
            if "httpupgradeSettings" not in ss or not isinstance(ss.get("httpupgradeSettings"), dict):
                ss["httpupgradeSettings"] = {}
            if ss["httpupgradeSettings"].get("host") != cdn_host:
                ss["httpupgradeSettings"]["host"] = cdn_host
                changed_host = True

        cur.execute("UPDATE inbounds SET stream_settings=? WHERE id=?", (json.dumps(ss), inb_id))
        con.commit()
    con.close()
    print("HOSTFIXED" if changed_host else "OK")
    sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)
PYEOF
}

# ============================================================
# NEW v4.0: reads the CURRENT live state back from the DB after
# writes are applied, so you can visually confirm — not assume —
# that every CDN-routed inbound's transport Host header, the
# cosmetic hosts.address, AND nginx's own Host header (which we
# always hardcode to $PRIMARY in make_location) all agree.
# ============================================================
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
        warn "Real browsers/clients will ALWAYS show 'not private' for this cert UNLESS the"
        warn "domain is Proxied (orange cloud) through Cloudflare, with SSL mode Full/Full(strict)."
        echo ""

        resolved_ip=$(resolve_domain_ips "$domain")
        if [ -n "$resolved_ip" ]; then
            local sample_ip; sample_ip=$(printf '%s' "$resolved_ip" | awk '{print $1}')
            if printf '%s' "$sample_ip" | grep -qE '^(173\.245\.|103\.21\.|103\.22\.|103\.31\.|141\.101\.|108\.162\.|190\.93\.|188\.114\.|197\.234\.|198\.41\.|162\.158\.|104\.16\.|104\.24\.|172\.6[4-9]\.|172\.7[01]\.|131\.0\.72\.)'; then
                ok "DNS check: ${domain} resolves to ${sample_ip}, which IS a Cloudflare IP range (Proxied / orange cloud). Good."
            else
                err "DNS check: ${domain} resolves to ${sample_ip}, which is NOT a Cloudflare IP."
                err "This means the domain is DNS-only (grey cloud) and clients connect DIRECTLY"
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
        ok "Certificate issuer does not look like a Cloudflare Origin CA cert. OK for direct trust."
    fi
}

# verify a shared certificate actually covers BOTH domains (SAN list, or
# CN as fallback for very old certs). Fails loudly if it doesn't, rather
# than letting nginx silently serve a cert that doesn't match one of the
# two server_names. A wildcard cert (*.example.com) covers both panel
# and CDN subdomains automatically as long as both are one-level subs.
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
# end-of-run summary tracks CDN-routed vs non-CDN inbounds explicitly so
# the user sees exactly what goes through CDN_DOMAIN and what stays
# direct/panel-only.
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

        # Host header for this nginx location is ALWAYS CDN_DOMAIN (PRIMARY),
        # explicitly, never the panel domain.
        LOCATIONS="${LOCATIONS}"$'\n'"$(make_location "$ltype" "$path" "$fport" "$PRIMARY")"
        echo -e "${CDN_BG} CDN-OK ${RESET} ${net} \"${remark}\" ${path} -> 127.0.0.1:${fport} (nginx Host header: ${PRIMARY}, exposed via CDN_DOMAIN:443)"
        CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [${net}] \"${remark}\" ${path} -> via ${PRIMARY} (CDN-proxied)"
        added=$((added+1))
    done

    [ "$added" -eq 0 ] && { warn "No CDN-compatible inbounds found."; return 1; }
    local AP; ask_optional AP "Apply DB changes (fix Host headers + rebuild hosts, CDN_DOMAIN=${PRIMARY})?" "[y/N]"
    if is_yes "$AP"; then
        cp "$db" "${db}.bak.$(date +%s)"
        HOSTFIX_SUMMARY=""
        for m in $(seq 1 "$op_count"); do
            mid="${OP_IDS[$m]}"; mfport="${OP_FPORTS[$m]}"; mnet="${OP_NETS[$m]}"; malpn="${OP_ALPNS[$m]}"
            sqlite3 "$db" "UPDATE inbounds SET listen='127.0.0.1', port=${mfport} WHERE id=${mid};"

            # THE FIX: strip_tls_py now takes CDN_DOMAIN as an explicit 4th
            # argument and force-writes the transport-level Host header
            # (wsSettings.headers.Host / xhttpSettings.host /
            # httpupgradeSettings.host) to it. Result string tells us
            # whether a mismatched Host was actually found and corrected.
            local tls_result
            tls_result=$(strip_tls_py "$db" "$mid" "$mnet" "$PRIMARY")
            if [ "$tls_result" = "HOSTFIXED" ]; then
                fix "Inbound #${mid} (${mnet}): transport Host header was WRONG (not ${PRIMARY}) — corrected now."
                HOSTFIX_SUMMARY="${HOSTFIX_SUMMARY}"$'\n'"  - Inbound #${mid} [${mnet}]: transport Host header corrected -> ${PRIMARY}"
            elif [ "$tls_result" != "OK" ]; then
                err "Inbound #${mid} (${mnet}): failed to update stream_settings — ${tls_result}"
            fi

            sqlite3 "$db" "DELETE FROM hosts WHERE inbound_id=${mid};"
            # address/sni/host_header for the x-ui "hosts" record (cosmetic
            # QR/subscription text) is explicitly $PRIMARY (== CDN_DOMAIN),
            # passed by name, never derived from the panel domain.
            insert_host_py "$db" "$mid" "$mnet" "$PRIMARY" "443" "$PRIMARY" "$malpn" >/dev/null
        done
        ok "Database updated (transport Host headers + hosts table all point to ${PRIMARY})! Restarting x-ui..."
        systemctl restart x-ui

        check_subscription_domain "$db"

        echo ""
        echo -e "${INFO}--- Verifying live binding (reading DB back, not trusting intent) ---${RESET}"
        print_verify_table "$db"
    fi
    return 0
}

# ============================================================
# REMOVED in v4.4: this script used to offer to set x-ui's GLOBAL
# subDomain setting to CDN_DOMAIN. That was wrong and is the exact
# bug you hit: subDomain is a single panel-wide value used to build
# the subscription link for EVERY inbound, including Reality,
# Hysteria2, gRPC, etc. Setting it to CDN_DOMAIN made x-ui's
# subscription PAGE display CDN_DOMAIN next to every inbound's
# config text — even ones this script never touched and that don't
# sit behind nginx/Cloudflare at all. Their actual stream_settings
# were untouched (correctly), but the subscription link text lied
# about the host, which is what you saw and correctly flagged.
# This script now NEVER touches subDomain/subEnable/subPort. If you
# want per-protocol correct subscription behavior, that has to be
# managed in x-ui itself (recent x-ui versions let you override the
# host per inbound in the inbound's own "Reset traffic"/client
# settings) — not via this global panel setting.
# ============================================================
check_subscription_domain() {
    local db="$1"
    warn "Subscription domain (x-ui subDomain) is a GLOBAL panel setting shared by"
    warn "ALL inbounds, including Reality/Hysteria2/gRPC ones this script never touches."
    warn "This script will NOT modify it, to avoid making non-CDN inbounds' subscription"
    warn "links falsely show ${PRIMARY}. If subscription links need per-protocol correctness,"
    warn "configure that inside x-ui itself, not through this script."
}

# ============================================================
# NEW v4.0: prints the live, re-read-from-DB state for every
# CDN-eligible inbound: transport Host header, hosts.address,
# hosts.host_header, and a MATCH/MISMATCH verdict against
# CDN_DOMAIN. This is the "show me, don't tell me" verification.
# ============================================================
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

# menu-accessible standalone verification (works without running install)
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
# NEW v4.4: repairs damage from OLDER versions of this script that
# used to set x-ui's global subDomain to CDN_DOMAIN. That setting is
# shared across ALL inbounds (Reality, Hysteria2, gRPC included), so
# it made every inbound's subscription-page text show CDN_DOMAIN even
# for protocols this script never touches and that are not behind
# nginx/Cloudflare at all. This menu action clears subDomain back to
# empty (x-ui then falls back to using the request host / panel
# domain per its own default behavior) so subscription text stops
# lying about non-CDN inbounds. It does NOT touch stream_settings,
# hosts table entries for ws/xhttp/httpupgrade, or anything this
# script correctly manages — only the global subDomain field.
# ============================================================
repair_global_subdomain() {
    local db=""; for c in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do [ -f "$c" ] && db="$c" && break; done
    [ -z "$db" ] && { err "x-ui database not found."; return 1; }

    local current
    current=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='subDomain' LIMIT 1;" 2>/dev/null)
    echo -e "${INFO}Current x-ui global subDomain value: ${current:-<empty>}${RESET}"
    warn "This value is shared by EVERY inbound's subscription link — including Reality/Hysteria2/gRPC"
    warn "ones this script never manages. If an older run of this script set it to your CDN domain,"
    warn "non-CDN inbounds would show the CDN domain in their subscription text (even though their"
    warn "real listen/port/stream_settings were never changed)."
    local CONFIRM; ask_optional CONFIRM "Clear subDomain now (recommended)?" "[y/N]"
    if is_yes "$CONFIRM"; then
        cp "$db" "${db}.bak.$(date +%s)"
        sqlite3 "$db" "UPDATE settings SET value='' WHERE key='subDomain';"
        fix "subDomain cleared. Restarting x-ui..."
        systemctl restart x-ui
        ok "Done. Subscription links will no longer force CDN_DOMAIN onto non-CDN inbounds."
    else
        warn "Left unchanged."
    fi
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
    CDN_ROUTED_SUMMARY=""; NONCDN_SUMMARY=""; HOSTFIX_SUMMARY=""

    echo -e "${INFO}=== Panel Configuration ===${RESET}"
    ask RAW_PANEL "Panel Domain / IP" "(e.g. panel.example.com — used ONLY for the x-ui admin panel + non-CDN inbounds)"
    PANEL_DOMAIN=$(strip_scheme "$RAW_PANEL"); PANEL_DOMAIN=$(strip_port "$PANEL_DOMAIN")
    ask_port PANEL_PORT "Panel Port" 2053

    echo -e "${INFO}=== CDN Configuration ===${RESET}"
    ask RAW_CDN "CDN Domain" "(e.g. cdn.example.com — this is the ONLY domain that goes through Cloudflare/Arvan proxy)"
    CDN_DOMAIN=$(strip_scheme "$RAW_CDN"); PRIMARY="$CDN_DOMAIN"
    ask_port HTTPS_PORT "HTTPS Port" 443
    ask_port HTTP_PORT  "HTTP Port"  80

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

    # No separate "is the panel domain proxied?" question. The panel domain
    # is NEVER touched by the CDN routing logic in this script regardless
    # of its Cloudflare proxy setting — only ws/httpupgrade/xhttp inbounds
    # get rewritten to CDN_DOMAIN. Asking about panel proxy status here
    # was redundant and added no protection; removed per explicit request.

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
        warn "Certificate does NOT cover the panel domain (${PANEL_DOMAIN})."
        warn "This is only a problem if you intend nginx/panel to present TLS for ${PANEL_DOMAIN} using this same cert."
        local PCONT; ask_optional PCONT "Continue anyway?" "[y/N]"
        is_yes "$PCONT" || { err "Aborted. Get a certificate (or SAN) that covers ${PANEL_DOMAIN} as well, or use a separate cert for the panel."; exit 1; }
    fi

    ensure_cert_renew_hook "$SSL_CERT"

    # No manual "Behind Cloudflare CDN?" question. You already told us the
    # CDN domain and got the cert from Cloudflare — asking again is
    # redundant. Detect it automatically: resolve CDN_DOMAIN and check if
    # the IP falls in a known Cloudflare range. If yes, real-IP restore is
    # enabled automatically. If the domain doesn't resolve to a Cloudflare
    # IP (e.g. Arvan, or proxy not yet turned on), we skip it silently —
    # you can still turn it on later via the firewall menu.
    BEHIND_CF=""
    local __cdn_ip; __cdn_ip=$(resolve_domain_ips "$CDN_DOMAIN" | awk '{print $1}')
    if [ -n "$__cdn_ip" ] && printf '%s' "$__cdn_ip" | grep -qE '^(173\.245\.|103\.21\.|103\.22\.|103\.31\.|141\.101\.|108\.162\.|190\.93\.|188\.114\.|197\.234\.|198\.41\.|162\.158\.|104\.16\.|104\.24\.|172\.6[4-9]\.|172\.7[01]\.|131\.0\.72\.)'; then
        ok "Detected ${CDN_DOMAIN} resolves to a Cloudflare IP (${__cdn_ip}) — enabling real-IP restore automatically."
        BEHIND_CF="y"
    else
        ok "${CDN_DOMAIN} does not currently resolve to a Cloudflare IP (or DNS lookup failed) — skipping real-IP restore. Enable it later from the firewall menu if you turn on the orange cloud."
    fi

    echo -e "${INFO}=== Inbounds ===${RESET}"
    local DISC; ask_choice DISC "Inbound discovery mode:" \
        "1:Auto (read from x-ui DB)" \
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
            ask_choice P_TYPE "Transport:" \
                "1:WebSocket / HTTPUpgrade" \
                "2:XHTTP"
            case "$P_TYPE" in
                1) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location upgrade "$P_PATH" "$P_PORT" "$PRIMARY")"
                   CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [ws/httpupgrade] ${P_PATH} -> via ${PRIMARY} (manual entry)"
                   warn "Manual entry does NOT touch x-ui's internal Host header field. Go into x-ui" ;;
                2) LOCATIONS="${LOCATIONS}"$'\n'"$(make_location xhttp "$P_PATH" "$P_PORT" "$PRIMARY")"
                   CDN_ROUTED_SUMMARY="${CDN_ROUTED_SUMMARY}"$'\n'"  - [xhttp] ${P_PATH} -> via ${PRIMARY} (manual entry)"
                   warn "Manual entry does NOT touch x-ui's internal Host header field. Go into x-ui" ;;
            esac
            warn "-> panel and set this inbound's WS/XHTTP Host header to ${PRIMARY} manually, or use Auto discovery instead."
            i=$((i+1))
        done
    fi

    echo -e "${INFO}=== Camouflage ===${RESET}"
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
        ask_file HTML_FILE "Path to index.html"
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

# write_config ONLY ever writes a server block for CDN_DOMAIN (server_name
# is CDN_DOMAIN, not panel domain). The panel is deliberately left OUT of
# this nginx vhost so it is never accidentally routed through the
# CDN-facing config. The x-ui panel continues to serve itself directly on
# PANEL_PORT via its own domain, entirely separate from this file.
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

    # PANEL_DOMAIN gets its OWN nginx TLS server block using the SAME
    # shared certificate (it covers both CDN_DOMAIN and PANEL_DOMAIN, as
    # confirmed by check_cert_covers_domain earlier). This block ONLY
    # proxies to the x-ui panel port — it carries NONE of the ws/xhttp/
    # httpupgrade locations, so Reality/gRPC/any other non-CDN inbound
    # keeps listening on its own port exactly as before, completely
    # untouched by this script.
    if [ "$PANEL_DOMAIN" != "$CDN_DOMAIN" ]; then
        local panel_conf="${NGINX_CONF_DIR}/${PANEL_DOMAIN}.conf"
        {
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
            echo "    access_log /var/log/nginx/${PANEL_DOMAIN}.access.log;"
            echo "    error_log  /var/log/nginx/${PANEL_DOMAIN}.error.log;"
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
        ok "Panel domain TLS block written (${PANEL_DOMAIN}:${HTTPS_PORT}) using the SAME shared certificate — proxies ONLY to panel port ${PANEL_PORT}. No CDN inbounds attached; Reality/gRPC/other non-CDN inbounds are untouched."
    fi

    if nginx -t; then
        if systemctl restart nginx; then
            ok "Nginx Configured & Running on HTTPS (${HTTPS_PORT}) for CDN_DOMAIN=${CDN_DOMAIN} and PANEL_DOMAIN=${PANEL_DOMAIN}!"
        else
            err "nginx -t passed but 'systemctl restart nginx' failed. Run: systemctl status nginx -l"
            return 1
        fi
    else
        err "nginx -t FAILED (see errors above). HTTPS config was written to ${conf} but NOT activated."
        return 1
    fi

    echo ""
    echo -e "${INFO}================= ROUTING SUMMARY =================${RESET}"
    echo -e "${C_LIME}CDN-proxied domain:${RESET}   ${CDN_DOMAIN}  (behind Cloudflare/Arvan, nginx terminates TLS here)"
    echo -e "${C_ROSE}Panel domain:${RESET}          ${PANEL_DOMAIN}  (nginx serves it via its own TLS block on the panel port only; not touched by CDN inbound routing)"
    if [ -n "$CDN_ROUTED_SUMMARY" ]; then
        echo -e "${CDN_BG} Inbounds routed through CDN_DOMAIN: ${RESET}"
        echo -e "${CDN_ROUTED_SUMMARY}"
    fi
    if [ -n "$NONCDN_SUMMARY" ]; then
        echo -e "${SKIP_BG} Inbounds left DIRECT (non-CDN, use PANEL_DOMAIN/IP): ${RESET}"
        echo -e "${NONCDN_SUMMARY}"
    fi
    if [ -n "$HOSTFIX_SUMMARY" ]; then
        echo -e "${FIX_BG} Backend Host-header mismatches corrected this run: ${RESET}"
        echo -e "${HOSTFIX_SUMMARY}"
    else
        ok "No backend Host-header mismatches found — everything was already consistent."
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

    local CDN_CHOICE; ask_choice CDN_CHOICE "CDN Provider:" \
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
        echo -e "  ${C_CYAN2}12) Verify CDN Host-header binding (live DB check)${RESET}"
        echo -e "  ${C_SLATE}13) Repair: clear global subDomain (fixes non-CDN inbounds showing CDN domain)${RESET}"
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
            13) repair_global_subdomain ;;
            14) full_uninstall ;;
            0)  exit 0 ;;
            *)  err "Invalid choice." ;;
        esac
        local _; ask_optional _ "Press Enter to continue..."
    done
}

require_root; menu
