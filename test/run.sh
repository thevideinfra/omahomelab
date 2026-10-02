#!/usr/bin/env bash
# Integration tests: runs status.sh / action.sh / setup.sh against test/mock_pve.py.
# usage: bash test/run.sh        (needs bash, curl, jq, openssl, python3, node)
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
T="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
check() { # check DESC JQ_FILTER JSON  -> passes when filter is true
  if printf '%s' "$3" | jq -e "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "$(printf '%s' "$3" | head -c 300)"; fi
}

TOKEN="root@pam!omarchy=11111111-2222-3333-4444-555555555555"
export XDG_CONFIG_HOME="$T/cfg"
mkdir -p "$XDG_CONFIG_HOME/omahomelab"

# self-signed cert for the TLS cases
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1" -keyout "$T/key.pem" -out "$T/cert.pem" >/dev/null 2>&1

start_mock() { # start_mock PORT [extra args]
  local port="$1"; shift
  python3 "$ROOT/test/mock_pve.py" --port "$port" "$@" &
  PIDS+=("$!")
  for _ in $(seq 1 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0
    sleep 0.1
  done
  echo "mock on $port did not start" >&2; return 1
}

start_mock 18081 --log "$T/http.log"
start_mock 18443 --cert "$T/cert.pem" --key "$T/key.pem" --log "$T/https.log"
start_mock 18082 --delay 2

status_http() { OMAHOMELAB_SCHEME=http bash "$ROOT/status.sh" --host 127.0.0.1 --port "${1:-18081}" "${@:2}"; }

echo "== setup states"
out="$(OMAHOMELAB_SCHEME=http bash "$ROOT/status.sh" --host "" --port 18081)"
check "no host -> not configured" '.configured == false and (.statusText | test("host"))' "$out"
out="$(status_http)"
check "no token -> not configured" '.configured == false and (.statusText | test("token"))' "$out"
out="$(OMAHOMELAB_TOKEN='garbage' status_http)"
check "malformed token rejected" '.configured == false and (.statusText | test("user@realm"))' "$out"
out="$(OMAHOMELAB_SCHEME=http OMAHOMELAB_TOKEN="$TOKEN" bash "$ROOT/status.sh" --host 'evil.com/@x' --port 18081)"
check "hostile host rejected before any request" '.configured == false and (.statusText | test("invalid"))' "$out"

echo "== status over http (token via env)"
out="$(OMAHOMELAB_TOKEN="$TOKEN" status_http)"
check "connected" '.configured and .lastError == "" and .statusText == "Connected"' "$out"
check "2 nodes, 5 guests" '(.nodes | length) == 2 and (.guests | length) == 5' "$out"
check "offline node kept, no NaN" '(.nodes[] | select(.name=="pve2") | .status == "offline" and .cpu == 0)' "$out"
check "guest fields" '(.guests[] | select(.vmid==100) | .name=="web" and .type=="qemu" and .status=="running" and .tags=="prod;web")' "$out"
check "template flagged" '(.guests[] | select(.vmid==102) | .template == true)' "$out"
check "lock surfaced" '(.guests[] | select(.vmid==201) | .lock == "backup")' "$out"
check "shared storage deduped, local kept per node" '(.storage | map(.name) | sort) == ["local","local-lvm","nfs"]' "$out"
check "token never echoed in output" '(tostring | contains("11111111") | not)' "$out"
check "auth header reached server" '.configured' "$out"
grep -q '"auth_ok": true' "$T/http.log" && ok "server saw correct PVEAPIToken header" || bad "server auth" "$(tail -2 "$T/http.log")"

echo "== token file + permissions warning"
printf '%s\n' "$TOKEN" >"$XDG_CONFIG_HOME/omahomelab/token"
chmod 644 "$XDG_CONFIG_HOME/omahomelab/token"
out="$(status_http)"
check "token file works" '.configured and .lastError == ""' "$out"
check "group/world-readable token warned" '.warning | test("chmod 600")' "$out"
chmod 600 "$XDG_CONFIG_HOME/omahomelab/token"
out="$(status_http)"
check "no warning at mode 600" '.warning == ""' "$out"

echo "== auth / API errors"
out="$(OMAHOMELAB_TOKEN='root@pam!omarchy=wrong-secret' status_http)"
check "bad secret -> 401 message" '.configured and (.lastError | test("Authentication failed"))' "$out"
out="$(status_http 18999)"
check "connection refused message" '.lastError | test("refused")' "$out"

echo "== TLS modes"
out="$(bash "$ROOT/status.sh" --host 127.0.0.1 --port 18443)"
check "self-signed cert rejected by default" '.lastError | test("TLS certificate not trusted")' "$out"
out="$(bash "$ROOT/status.sh" --host 127.0.0.1 --port 18443 --insecure 1)"
check "--insecure connects" '.lastError == "" and .configured' "$out"
out="$(bash "$ROOT/status.sh" --host 127.0.0.1 --port 18443 --ca "$T/cert.pem")"
check "--ca pinned cert connects" '.lastError == "" and .configured' "$out"
cp "$T/cert.pem" "$XDG_CONFIG_HOME/omahomelab/pve.pem"
out="$(bash "$ROOT/status.sh" --host 127.0.0.1 --port 18443)"
check "~/.config/omahomelab/pve.pem picked up automatically" '.lastError == "" and .configured' "$out"
rm -f "$XDG_CONFIG_HOME/omahomelab/pve.pem"

echo "== actions"
act() { OMAHOMELAB_SCHEME=http OMAHOMELAB_TOKEN="$TOKEN" bash "$ROOT/action.sh" --host 127.0.0.1 --port 18081 "$@"; }
out="$(act --op shutdown --node pve1 --type qemu --vmid 100)"
check "shutdown ok" '.ok and (.message | test("shutdown requested"))' "$out"
grep -q '"path": "/api2/json/nodes/pve1/qemu/100/status/shutdown"' "$T/http.log" && ok "hit the right endpoint" || bad "endpoint" "$(tail -3 "$T/http.log")"
tail -20 "$T/http.log" | grep 'status/shutdown' | grep -q '"content_length": "0"' && ok "POST sends Content-Length: 0" || bad "content-length" ""
out="$(act --op start --node pve1 --type qemu --vmid 100)"
check "API error text surfaced" '(.ok | not) and (.message | test("already running"))' "$out"
out="$(act --op start --node pve1 --type qemu --vmid 999)"
check "unknown vm error surfaced" '(.ok | not) and (.message | test("does not exist"))' "$out"
out="$(act --op reset --node pve1 --type lxc --vmid 200)"
check "reset refused for containers" '(.ok | not) and (.message | test("only available for virtual machines"))' "$out"
out="$(act --op nuke --node pve1 --type qemu --vmid 100)"
check "unknown op refused" '(.ok | not) and (.message | test("Unknown action"))' "$out"
out="$(act --op start --node '../etc' --type qemu --vmid 100)"
check "path-traversal node refused" '(.ok | not) and (.message | test("Invalid node"))' "$out"
out="$(act --op start --node pve1 --type qemu --vmid '100/../../x')"
check "bad vmid refused" '(.ok | not) and (.message | test("Invalid VM id"))' "$out"
out="$(act --op snapshot --node pve1 --type lxc --vmid 200)"
check "snapshot ok" '.ok and (.message | test("omahomelab-[0-9]{8}-[0-9]{6}"))' "$out"
grep -q 'description=Created' "$T/http.log" && ok "snapshot description url-encoded/sent" || bad "snapshot body" "$(tail -2 "$T/http.log")"

echo "== spice"
out="$(act --op spice --node pve1 --type qemu --vmid 100)"
check "spice without remote-viewer fails clearly" '(.ok | not) and (.message | test("virt-viewer"))' "$out"
mkdir -p "$T/bin"
cat >"$T/bin/remote-viewer" <<EOF
#!/usr/bin/env bash
cp "\$1" "$T/spice-seen.vv"
EOF
chmod +x "$T/bin/remote-viewer"
export XDG_RUNTIME_DIR="$T"
out="$(PATH="$T/bin:$PATH" act --op spice --node pve1 --type qemu --vmid 100)"
check "spice launches" '.ok' "$out"
for _ in $(seq 1 30); do [ -s "$T/spice-seen.vv" ] && break; sleep 0.1; done
head -1 "$T/spice-seen.vv" | grep -q '^\[virt-viewer\]$' && ok ".vv starts with [virt-viewer]" || bad ".vv header" "$(head -3 "$T/spice-seen.vv" 2>&1)"
grep -q '^host=pvespiceproxy:' "$T/spice-seen.vv" && grep -q '^delete-this-file=1$' "$T/spice-seen.vv" && ok ".vv has host + delete-this-file" || bad ".vv fields" "$(cat "$T/spice-seen.vv")"
grep -q '^ca=-----BEGIN CERTIFICATE-----\\n' "$T/spice-seen.vv" && ok ".vv keeps literal \\n in ca" || bad ".vv ca" "$(grep '^ca=' "$T/spice-seen.vv")"
mode="$(ls -l "$T"/omahomelab-*.vv 2>/dev/null | head -1 | cut -c1-10)"
[ -z "$mode" ] || [ "$mode" = "-rw-------" ] && ok ".vv file is private (0600)" || bad ".vv mode" "$mode"
out="$(PATH="$T/bin:$PATH" act --op spice --node pve1 --type lxc --vmid 200)"
check "spice error surfaced" '(.ok | not) and (.message | test("no spice port"))' "$out"

echo "== token is not visible in the process list"
( OMAHOMELAB_SCHEME=http OMAHOMELAB_TOKEN="$TOKEN" bash "$ROOT/status.sh" --host 127.0.0.1 --port 18082 >"$T/slow.out" ) &
SLOW=$!
sleep 0.8
if ps -eo args | grep -F '11111111-2222' | grep -v grep >/dev/null; then
  bad "token leaked into ps output" "$(ps -eo args | grep -F '11111111-2222' | grep -v grep | head -2)"
else
  ps -eo args | grep -q '[c]url.*18082' && ok "curl was running during check, token absent from argv" || bad "could not observe curl" ""
fi
wait "$SLOW"

echo "== setup.sh (interactive helper, piped input)"
out="$(printf '%s\ny\n\n' "$TOKEN" | bash "$ROOT/setup.sh" --host 127.0.0.1 --port 18443 2>&1)"
[ -s "$XDG_CONFIG_HOME/omahomelab/token" ] && ok "setup wrote token file" || bad "setup token" "$out"
[ "$(stat -c %a "$XDG_CONFIG_HOME/omahomelab/token")" = "600" ] && ok "token file mode 600" || bad "token mode" "$(stat -c %a "$XDG_CONFIG_HOME/omahomelab/token")"
[ "$(stat -c %a "$XDG_CONFIG_HOME/omahomelab")" = "700" ] && ok "config dir mode 700" || bad "dir mode" ""
[ -s "$XDG_CONFIG_HOME/omahomelab/pve.pem" ] && ok "setup pinned the certificate" || bad "setup pin" "$out"
printf '%s' "$out" | grep -q 'OK: 2 node(s), 5 guest(s) visible' && ok "setup connection test passed over pinned TLS" || bad "setup test" "$out"
printf '%s' "$out" | grep -q '11111111' && bad "setup echoed the secret" "" || ok "setup did not echo the secret"
out="$(printf 'not-a-token\n\n' | bash "$ROOT/setup.sh" --host 127.0.0.1 --port 18443 2>&1)"
printf '%s' "$out" | grep -q 'Nothing was saved' && ok "setup rejects malformed token" || bad "setup malformed" "$out"

echo "== model (node)"
if command -v node >/dev/null 2>&1; then
  node "$ROOT/test/model.test.js" && ok "Model.js tests" || bad "Model.js tests" ""
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
