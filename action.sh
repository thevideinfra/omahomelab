#!/usr/bin/env bash
# Performs one action on one guest and prints {"ok":bool,"message":"..."}.
#
# usage: action.sh --host H --port P [--ca F] [--insecure 0|1] \
#                  --op start|shutdown|stop|reboot|reset|suspend|resume|snapshot|spice \
#                  --node NODE --type qemu|lxc --vmid ID

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
parse_args "$@"

result() { # result true|false MESSAGE
  jq -n --argjson ok "$1" --arg message "$2" '{ok:$ok, message:$message}'
}

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  printf '{"ok":false,"message":"curl and jq are required"}\n'
  exit 0
fi

valid_host || { result false "Host or port looks invalid"; exit 0; }
[[ "$NODE" =~ ^[A-Za-z0-9._-]+$ ]] || { result false "Invalid node name"; exit 0; }
[[ "$VMID" =~ ^[0-9]{1,12}$ ]] || { result false "Invalid VM id"; exit 0; }
case "$TYPE" in qemu|lxc) ;; *) result false "Invalid guest type"; exit 0 ;; esac

resolve_tls
load_token
valid_token || { result false "No valid API token — run setup"; exit 0; }

base="/nodes/$NODE/$TYPE/$VMID"

case "$OP" in
  start|shutdown|stop|reboot)
    ;;
  reset|suspend|resume)
    if [ "$TYPE" != "qemu" ]; then
      result false "$OP is only available for virtual machines"
      exit 0
    fi
    ;;
  snapshot|spice)
    ;;
  *)
    result false "Unknown action: $OP"
    exit 0
    ;;
esac

case "$OP" in
  start|shutdown|stop|reboot|reset|suspend|resume)
    if api POST "$base/status/$OP" -d ""; then
      result true "$OP requested for $TYPE $VMID ($(printf '%s' "$API_BODY" | jq -r '.data // empty' | cut -c1-40))"
    else
      result false "$OP failed: $(api_error)"
    fi
    ;;

  snapshot)
    snap="omaprox-$(date +%Y%m%d-%H%M%S)"
    if api POST "$base/snapshot" -d "snapname=$snap" --data-urlencode "description=Created from the Omarchy bar"; then
      result true "Snapshot $snap requested for $TYPE $VMID"
    else
      result false "Snapshot failed: $(api_error)"
    fi
    ;;

  spice)
    if ! command -v remote-viewer >/dev/null 2>&1; then
      result false "remote-viewer not found — install virt-viewer"
      exit 0
    fi
    if ! api POST "$base/spiceproxy" -d ""; then
      result false "SPICE unavailable: $(api_error)"
      exit 0
    fi
    if ! printf '%s' "$API_BODY" | jq -e '.data.host' >/dev/null 2>&1; then
      result false "SPICE unavailable: server returned no connection details"
      exit 0
    fi
    # The connection file carries a one-time ticket, so keep it private.
    # Proxmox sets delete-this-file=1, so remote-viewer removes it after reading.
    vv="$(umask 077 && mktemp "${XDG_RUNTIME_DIR:-/tmp}/omaprox-XXXXXX.vv")"
    {
      printf '[virt-viewer]\n'
      printf '%s' "$API_BODY" | jq -r '.data | to_entries[] | "\(.key)=\(.value)"'
    } >"$vv"
    nohup remote-viewer "$vv" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    result true "Opening SPICE console for $TYPE $VMID"
    ;;
esac
