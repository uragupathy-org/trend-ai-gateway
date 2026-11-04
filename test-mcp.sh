#!/usr/bin/env bash
# Runs the MCP handshake and access-rule checks against the gateway's MCP proxy.
#
#   export AI_GATEWAY_KEY='<virtual key>'
#   kubectl -n trendai-gateway port-forward svc/trendai-gateway-gateway 8081:8081 &
#   ./test-mcp.sh [--url http://localhost:8081/] [--verbose]
#
# Checks:
#   1. initialize                  -> 200 with protocolVersion
#   2. notifications/initialized   -> 202 (or 200)
#   3. tools/list                  -> safe and restricted tools are listed
#   4. tools/call safe add_numbers -> result, no error
#   5. tools/call restricted tool  -> denied by Access Control: JSON-RPC error in a 200 body
#
# Exit code: 0 when every check passes, 1 otherwise.
set -uo pipefail

MCP_URL="${MCP_URL:-http://localhost:8081/}"
SAFE_SERVER="${SAFE_SERVER:-Mock-MCP-Safe-Server}"
RESTRICTED_SERVER="${RESTRICTED_SERVER:-Mock-MCP-Restricted-Server}"
VERBOSE=false

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)     MCP_URL="${2:?--url needs a value}"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd" >&2; exit 2; }
done
: "${AI_GATEWAY_KEY:?set AI_GATEWAY_KEY to a virtual key from Vision One}"

pass=0
fail=0
SESSION_ID=""

# Prints the JSON-RPC payload from a response body. Handles plain JSON and
# server-sent events (the last "data:" line).
payload_of() {
  local body="$1"
  if grep -q '^data: ' <<<"$body"; then
    sed -n 's/^data: //p' <<<"$body" | tail -n 1
  else
    printf '%s' "$body"
  fi
}

# rpc <json> -> sets CODE, BODY (raw), PAYLOAD (JSON)
rpc() {
  local json="$1"
  local hdrs body_file hdr_file
  body_file=$(mktemp); hdr_file=$(mktemp)
  local args=(-sS --max-time 60 -o "$body_file" -D "$hdr_file" -X POST "$MCP_URL"
    -H "Authorization: Bearer $AI_GATEWAY_KEY"
    -H "Content-Type: application/json"
    -H "Accept: application/json, text/event-stream"
    -d "$json")
  [[ -n "$SESSION_ID" ]] && args+=(-H "Mcp-Session-Id: $SESSION_ID")
  CODE=$(curl "${args[@]}" -w '%{http_code}' 2>/dev/null || echo "000")
  BODY=$(cat "$body_file")
  hdrs=$(tr -d '\r' < "$hdr_file")
  if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID=$(awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' <<<"$hdrs")
  fi
  PAYLOAD=$(payload_of "$BODY")
  rm -f "$body_file" "$hdr_file"
}

report() {
  local name="$1" result="$2" detail="$3"
  if [[ "$result" == "PASS" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
  printf '%-34s %-6s %s\n' "$name" "$result" "$detail"
  if [[ "$VERBOSE" == true ]]; then
    echo "    http: $CODE"
    echo "    body: $(head -c 300 <<<"$BODY" | tr '\n' ' ')"
  fi
}

printf 'MCP endpoint: %s\n' "$MCP_URL"
printf '%-34s %-6s %s\n' "CHECK" "RESULT" "DETAIL"
printf '%s\n' "--------------------------------------------------------------------------------"

# 1. initialize
rpc '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-mcp.sh","version":"1.0"}}}'
if [[ "$CODE" == "200" ]] && jq -e '.result.protocolVersion' <<<"$PAYLOAD" >/dev/null 2>&1; then
  report "1 initialize" PASS "session: ${SESSION_ID:-none returned}"
else
  report "1 initialize" FAIL "HTTP $CODE"
fi

# 2. notifications/initialized
rpc '{"jsonrpc":"2.0","method":"notifications/initialized"}'
if [[ "$CODE" == "202" || "$CODE" == "200" ]]; then
  report "2 notifications/initialized" PASS "HTTP $CODE"
else
  report "2 notifications/initialized" FAIL "HTTP $CODE"
fi

# 3. tools/list
rpc '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
safe_tool="${SAFE_SERVER}__add_numbers"
restricted_tool="${RESTRICTED_SERVER}__delete_customer_record"
names=$(jq -r '.result.tools[]?.name' <<<"$PAYLOAD" 2>/dev/null)
if grep -qx "$safe_tool" <<<"$names" && grep -qx "$restricted_tool" <<<"$names"; then
  report "3 tools/list" PASS "$(wc -l <<<"$names" | tr -d ' ') tools listed"
else
  report "3 tools/list" FAIL "expected $safe_tool and $restricted_tool"
fi

# 4. safe tool call: must succeed
rpc "$(jq -nc --arg n "$safe_tool" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$n,arguments:{a:3,b:4}}}')"
text=$(jq -r '.result.content[0].text // empty' <<<"$PAYLOAD" 2>/dev/null)
if [[ "$CODE" == "200" ]] && ! jq -e '.error' <<<"$PAYLOAD" >/dev/null 2>&1 && [[ "$text" == *"7"* ]]; then
  report "4 safe tool call (allowed)" PASS "$text"
else
  report "4 safe tool call (allowed)" FAIL "HTTP $CODE, expected a result containing 7"
fi

# 5. restricted tool call: must be denied by Access Control
rpc "$(jq -nc --arg n "$restricted_tool" '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:$n,arguments:{customer_id:"CUST-10492"}}}')"
err=$(jq -r '.error.message // empty' <<<"$PAYLOAD" 2>/dev/null)
if [[ "$CODE" == "200" && "$err" == *"blocked by access policy"* ]]; then
  report "5 restricted tool call (denied)" PASS "$err"
elif [[ "$CODE" == "200" && -z "$err" ]]; then
  report "5 restricted tool call (denied)" FAIL "call went through; the Forbid rule is not applied to $RESTRICTED_SERVER"
else
  report "5 restricted tool call (denied)" FAIL "HTTP $CODE, error: ${err:-none}"
fi

printf '%s\n' "--------------------------------------------------------------------------------"
printf 'Passed: %d   Failed: %d\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
