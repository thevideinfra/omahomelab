#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by the scripts that source this file
# omahomelab shared helpers — sourced by status.sh, action.sh and setup.sh.
#
# Design rules:
#   * The API token is read from $OMAHOMELAB_TOKEN or ~/.config/omahomelab/token. It is
#     never written to shell.json and never placed on a command line: curl gets
#     it as a header over stdin (-H @-), so it does not show up in `ps`.
#   * TLS is verified by default. Trust comes from a pinned certificate
#     (--ca, or ~/.config/omahomelab/pve.pem if present) or, only if the user opts
#     in, --insecure.
#   * Every value that ends up in a URL is validated first.

HOST=""
PORT="8006"
CA=""
INSECURE="0"
OP=""
NODE=""
TYPE=""
VMID=""
# Test hook only. The real Proxmox API is HTTPS-only.
SCHEME="${OMAHOMELAB_SCHEME:-https}"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omahomelab"
TOKEN=""
TOKEN_WARNING=""
API_BODY=""
API_CODE=0
API_RC=0
API_ERR=""
API_REASON=""

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --host)     HOST="${2:-}" ;;
      --port)     PORT="${2:-8006}" ;;
      --ca)       CA="${2:-}" ;;
      --insecure) INSECURE="${2:-0}" ;;
      --op)       OP="${2:-}" ;;
      --node)     NODE="${2:-}" ;;
      --type)     TYPE="${2:-}" ;;
      --vmid)     VMID="${2:-}" ;;
    esac
    shift
    [ $# -gt 0 ] && shift
  done
  [ -n "$PORT" ] || PORT=8006
}

# Expand a leading ~ and fall back to the pinned cert from `setup.sh`.
resolve_tls() {
  CA="${CA/#\~/$HOME}"
  if [ -z "$CA" ] && [ -r "$CONFIG_DIR/pve.pem" ]; then
    CA="$CONFIG_DIR/pve.pem"
  fi
}

valid_host() {
  # In a POSIX bracket expression "]" must come first and "-" last.
  local re='^[][A-Za-z0-9._:-]+$'
  [[ "$HOST" =~ $re ]] && [[ "$PORT" =~ ^[0-9]{1,5}$ ]]
}

host_port() {
  local h="$HOST"
  case "$h" in
    \[*) ;;
    *:*) h="[$h]" ;; # bare IPv6 literal
  esac
  printf '%s:%s' "$h" "$PORT"
}

load_token() {
  TOKEN="${OMAHOMELAB_TOKEN:-}"
  TOKEN_WARNING=""
  if [ -z "$TOKEN" ]; then
    local f="${OMAHOMELAB_TOKEN_FILE:-$CONFIG_DIR/token}"
    if [ -r "$f" ]; then
      TOKEN="$(head -n1 "$f" | tr -d '\r\n ')"
      local mode
      mode="$(stat -c %a "$f" 2>/dev/null || true)"
      case "$mode" in
        ""|400|600) ;;
        *) TOKEN_WARNING="Token file is readable by other users — run: chmod 600 $f" ;;
      esac
    fi
  fi
}

# user@realm!tokenid=secret
valid_token() {
  [[ "$TOKEN" =~ ^[^@!=[:space:]]+@[^@!=[:space:]]+![^@!=[:space:]]+=[^[:space:]]+$ ]]
}

# api METHOD PATH [extra curl args...]
# Sets API_BODY, API_CODE, API_RC, API_ERR, API_REASON. Returns 0 only on HTTP 2xx.
api() {
  local method="$1" path="$2"
  shift 2
  local url
  url="$SCHEME://$(host_port)/api2/json$path"
  local tls=()
  if [ -n "$CA" ]; then
    tls=(--cacert "$CA")
  elif [ "$INSECURE" = "1" ]; then
    tls=(--insecure)
  fi

  local out rc
  : >"$TMPD/hdr"
  out="$(printf 'Authorization: PVEAPIToken=%s\n' "$TOKEN" |
    curl -sS --max-time "${OMAHOMELAB_TIMEOUT:-10}" -X "$method" -H @- \
      -D "$TMPD/hdr" "${tls[@]}" "$@" -w '\n%{http_code}' "$url" 2>"$TMPD/err")"
  rc=$?

  API_RC=$rc
  API_ERR="$(tr '\n' ' ' <"$TMPD/err")"
  API_REASON="$(sed -n '1s/^HTTP\/[0-9.]* [0-9]* *//p' "$TMPD/hdr" | tr -d '\r')"
  if [ "$rc" -ne 0 ]; then
    API_CODE=0
    API_BODY=""
    return 1
  fi
  API_CODE="${out##*$'\n'}"
  API_BODY="${out%$'\n'*}"
  case "$API_CODE" in
    2??) return 0 ;;
    *) return 1 ;;
  esac
}

# Human-readable reason for the last failed api() call.
api_error() {
  if [ "$API_CODE" = "0" ]; then
    case "$API_RC" in
      6)  echo "Cannot resolve host $HOST" ;;
      7)  echo "Connection refused at $(host_port)" ;;
      28) echo "Timed out talking to $(host_port)" ;;
      35|51|58|60|77|83)
        echo "TLS certificate not trusted — run setup to pin it, or enable Insecure TLS" ;;
      *)  echo "Request failed: $(printf '%s' "$API_ERR" | cut -c1-120)" ;;
    esac
    return
  fi
  case "$API_CODE" in
    401) echo "Authentication failed — check the API token" ;;
    403) echo "Permission denied — ${API_REASON:-the API token lacks the required role}" ;;
    *)
      local m
      m="$(printf '%s' "$API_BODY" | jq -r '(.message // empty)' 2>/dev/null | head -c 160)"
      echo "${m:-${API_REASON:-HTTP $API_CODE}}"
      ;;
  esac
}
