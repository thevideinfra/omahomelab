#!/usr/bin/env bash
# Emits one JSON object describing the cluster: nodes, guests (VMs + containers)
# and storage. Always exits 0 and reports problems in "lastError"/"statusText",
# so the widget can show them instead of guessing from an exit code.
#
# usage: status.sh --host HOST --port 8006 [--ca FILE] [--insecure 0|1]

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
parse_args "$@"

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  printf '{"ok":true,"installed":false,"configured":false,"statusText":"curl and jq are required","lastError":""}\n'
  exit 0
fi

# basic CONFIGURED STATUS_TEXT LAST_ERROR
basic() {
  jq -n --argjson configured "$1" --arg statusText "$2" --arg lastError "$3" \
    --arg host "$HOST" --arg warning "$TOKEN_WARNING" \
    '{ok:true, installed:true, configured:$configured, statusText:$statusText,
      lastError:$lastError, warning:$warning, host:$host,
      nodes:[], guests:[], storage:[]}'
}

if [ -z "$HOST" ]; then
  basic false "Set the Proxmox host in the widget settings" ""
  exit 0
fi
if ! valid_host; then
  basic false "Host or port looks invalid" ""
  exit 0
fi

resolve_tls
load_token
if [ -z "$TOKEN" ]; then
  basic false "No API token yet — run setup" ""
  exit 0
fi
if ! valid_token; then
  basic false "API token should look like user@realm!name=secret" ""
  exit 0
fi

if ! api GET /cluster/resources; then
  basic true "Unreachable" "$(api_error)"
  exit 0
fi

if ! printf '%s' "$API_BODY" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
  basic true "Unexpected response" "The server did not return a Proxmox resource list"
  exit 0
fi

printf '%s' "$API_BODY" | jq \
  --arg host "$HOST" --arg warning "$TOKEN_WARNING" --argjson now "$(date +%s)" '
  def n: . // 0;
  {
    ok: true,
    installed: true,
    configured: true,
    statusText: "Connected",
    lastError: "",
    warning: $warning,
    host: $host,
    fetchedAt: $now,
    nodes: ([.data[] | select(.type == "node") | {
        name: .node, status: (.status // "unknown"),
        cpu: (.cpu | n), maxcpu: (.maxcpu | n),
        mem: (.mem | n), maxmem: (.maxmem | n), uptime: (.uptime | n)
      }] | sort_by(.name)),
    guests: ([.data[] | select(.type == "qemu" or .type == "lxc") | {
        vmid: .vmid, name: (.name // ("guest-" + (.vmid | tostring))),
        type: .type, node: .node, status: (.status // "unknown"),
        cpu: (.cpu | n), maxcpu: (.maxcpu | n),
        mem: (.mem | n), maxmem: (.maxmem | n), uptime: (.uptime | n),
        tags: (.tags // ""), lock: (.lock // ""),
        template: ((.template // 0) == 1)
      }] | sort_by(.vmid)),
    storage: ([.data[] | select(.type == "storage") | {
        name: .storage, node: .node, shared: ((.shared // 0) == 1),
        used: (.disk | n), total: (.maxdisk | n), status: (.status // "unknown")
      }] | unique_by(if .shared then .name else (.name + "@" + .node) end))
  }'
