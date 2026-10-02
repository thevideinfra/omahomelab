#!/usr/bin/env bash
# Interactive first-run helper. The widget opens this in a terminal.
#   1. stores your Proxmox API token in ~/.config/omahomelab/token (mode 600)
#   2. optionally pins the server certificate to ~/.config/omahomelab/pve.pem
#   3. tests the connection
#
# usage: setup.sh [--host HOST] [--port 8006]

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
parse_args "$@"

pause() { printf '\nPress Enter to close. '; read -r _ || true; }

echo "Proxmox setup for the Omarchy bar"
echo "================================="
echo

if [ -z "$HOST" ]; then
  read -r -p "Proxmox host (name or IP): " HOST
  echo "  -> Also set this as 'Host' in the widget settings."
fi
if ! valid_host; then
  echo "That host or port looks invalid."
  pause
  exit 1
fi

cat <<EOF

Create an API token in the Proxmox web UI:
  Datacenter -> Permissions -> API Tokens -> Add
Then grant it a role under Datacenter -> Permissions:
  view only:      PVEAuditor on path /
  power/console:  a role with VM.PowerMgmt + VM.Console (e.g. PVEVMUser) on /vms
(If you leave "Privilege Separation" ticked, the token needs its own roles.)

The token looks like:  user@realm!name=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
EOF
echo

read -r -s -p "Paste API token (input hidden): " TOKEN
echo
if ! valid_token; then
  echo "That does not look like user@realm!name=secret. Nothing was saved."
  pause
  exit 1
fi

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
(umask 077 && printf '%s\n' "$TOKEN" >"$CONFIG_DIR/token")
chmod 600 "$CONFIG_DIR/token"
echo "Saved token to $CONFIG_DIR/token"
echo

# ---- TLS -------------------------------------------------------------------
if [ ! -r "$CONFIG_DIR/pve.pem" ] && command -v openssl >/dev/null 2>&1; then
  echo "Fetching the server certificate from $(host_port) ..."
  pem="$(openssl s_client -connect "$(host_port)" -servername "$HOST" </dev/null 2>/dev/null |
    openssl x509 -outform PEM 2>/dev/null)"
  if [ -n "$pem" ]; then
    fp="$(printf '%s\n' "$pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null)"
    echo "  $fp"
    echo "  Compare this with the fingerprint shown in the Proxmox web UI"
    echo "  (Node -> System -> Certificates) before you trust it."
    read -r -p "Pin this certificate? [y/N] " ans
    case "$ans" in
      y|Y)
        (umask 077 && printf '%s\n' "$pem" >"$CONFIG_DIR/pve.pem")
        echo "Pinned to $CONFIG_DIR/pve.pem (re-run setup if the certificate is renewed)."
        ;;
      *) echo "Not pinned. Set 'CA certificate' in the widget settings, or enable 'Insecure TLS'." ;;
    esac
  else
    echo "Could not fetch a certificate (is the host reachable?)."
  fi
  echo
fi

# ---- test ------------------------------------------------------------------
echo "Testing connection ..."
out="$(bash "$DIR/status.sh" --host "$HOST" --port "$PORT" --ca "$CA" --insecure "$INSECURE")"
if [ "$(printf '%s' "$out" | jq -r '.lastError')" = "" ] && [ "$(printf '%s' "$out" | jq -r '.configured')" = "true" ]; then
  printf '%s' "$out" | jq -r '"OK: \(.nodes | length) node(s), \(.guests | length) guest(s) visible"'
else
  printf 'Problem: %s\n' "$(printf '%s' "$out" | jq -r '.lastError, .statusText' | grep -v '^$' | head -1)"
fi
pause
