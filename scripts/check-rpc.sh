#!/bin/sh
# Explorer RPC preflight — ENGINEERING.md §5.2 "Explorer RPC target is an archive
# node, not pruned" and §6.5 "Blockscout requires debug_traceTransaction".
#
# Refuses (exit 1) unless the target RPC:
#   1. answers eth_chainId with the expected EIP-155 id;
#   2. serves historical state — eth_getBalance at block 1 (a pruned node keeps
#      only the last `pruning-keep-recent` heights and errors on old ones);
#   3. exposes the debug namespace — debug_traceBlockByNumber on the latest
#      block returns a result, and debug_traceTransaction is a known method;
#   4. (if RPC_WS_URL is set) accepts a WebSocket upgrade on the ws endpoint,
#      which Blockscout uses for the newHeads subscription.
#
# POSIX sh + curl + sed/grep only, so the same script runs on a laptop and
# inside the `rpc-preflight` compose service (curlimages/curl has no jq).
#
# Usage:
#   RPC_HTTP_URL=http://127.0.0.1:8545 CHAIN_ID=56670 scripts/check-rpc.sh
#   RPC_HTTP_URL=... RPC_TRACE_URL=... RPC_WS_URL=ws://... CHAIN_ID=... scripts/check-rpc.sh
#
# Environment:
#   RPC_HTTP_URL   (required) JSON-RPC over HTTP
#   RPC_TRACE_URL  (optional) endpoint used for debug_* — defaults to RPC_HTTP_URL
#   RPC_WS_URL     (optional) ws:// or wss:// endpoint for subscriptions
#   CHAIN_ID       (required) expected decimal EIP-155 chain id
#   ARCHIVE_PROBE_ADDRESS (optional) address to query at block 1; any address
#                  works — the check is that the node *answers* for an old
#                  height, not what the balance is. Defaults to the zero address.
#   TRACE_TX_HASH  (optional) a tx hash to trace; if unset the script looks for
#                  one in the last 50 blocks and otherwise only checks that the
#                  method is registered.
#   CURL_MAX_TIME  (optional) per-request timeout in seconds, default 15.

set -u

RPC_HTTP_URL="${RPC_HTTP_URL:-}"
RPC_TRACE_URL="${RPC_TRACE_URL:-$RPC_HTTP_URL}"
RPC_WS_URL="${RPC_WS_URL:-}"
CHAIN_ID="${CHAIN_ID:-}"
ARCHIVE_PROBE_ADDRESS="${ARCHIVE_PROBE_ADDRESS:-0x0000000000000000000000000000000000000000}"
TRACE_TX_HASH="${TRACE_TX_HASH:-}"
CURL_MAX_TIME="${CURL_MAX_TIME:-15}"

fail() { printf 'check-rpc: FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'check-rpc: ok   %s\n' "$*"; }
note() { printf 'check-rpc: note %s\n' "$*"; }

[ -n "$RPC_HTTP_URL" ] || fail "RPC_HTTP_URL is not set"
[ -n "$CHAIN_ID" ] || fail "CHAIN_ID is not set"
command -v curl >/dev/null 2>&1 || fail "curl not found"

# rpc URL METHOD PARAMS-JSON  → raw JSON body on stdout; exit 1 on transport error
rpc() {
  _url="$1"; _method="$2"; _params="$3"
  # --retry-connrefused: a node whose accept queue is briefly full (an indexer
  # opening its connection pool at the same moment) refuses for a moment;
  # that is not "not an archive node".
  curl -sS --max-time "$CURL_MAX_TIME" --retry 3 --retry-connrefused --retry-delay 2 \
    -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$_method\",\"params\":$_params}" \
    "$_url" 2>/dev/null
}

# has_result BODY → true if the body carries a non-null "result"
has_result() {
  printf '%s' "$1" | grep -q '"result":' && ! printf '%s' "$1" | grep -Eq '"result":[[:space:]]*null'
}

# error_code BODY → the numeric "code" inside "error", or empty
error_code() {
  printf '%s' "$1" | sed -n 's/.*"error":[[:space:]]*{[^}]*"code":[[:space:]]*\(-\{0,1\}[0-9]*\).*/\1/p' | head -n 1
}

# error_message BODY → the "message" inside "error", or empty
error_message() {
  printf '%s' "$1" | sed -n 's/.*"error":[[:space:]]*{[^}]*"message":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

# string_result BODY → the value of a string "result"
string_result() {
  printf '%s' "$1" | sed -n 's/.*"result":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

hex_to_dec() {
  # $1 like 0xdd5e
  _h=$(printf '%s' "$1" | sed 's/^0[xX]//')
  [ -n "$_h" ] || { echo ""; return; }
  printf '%d' "0x$_h" 2>/dev/null
}

# ---- 1. reachable + right chain -------------------------------------------
body=$(rpc "$RPC_HTTP_URL" eth_chainId '[]') || fail "cannot reach $RPC_HTTP_URL"
has_result "$body" || fail "eth_chainId returned no result from $RPC_HTTP_URL: $body"
got_hex=$(string_result "$body")
got_dec=$(hex_to_dec "$got_hex")
[ "$got_dec" = "$CHAIN_ID" ] || fail "eth_chainId is $got_dec ($got_hex), expected $CHAIN_ID — wrong network, refusing to index it"
ok "eth_chainId = $CHAIN_ID"

body=$(rpc "$RPC_HTTP_URL" eth_blockNumber '[]') || fail "eth_blockNumber failed"
has_result "$body" || fail "eth_blockNumber returned no result: $body"
head_hex=$(string_result "$body")
head_dec=$(hex_to_dec "$head_hex")
ok "head block = $head_dec"

# ---- 2. archive state ------------------------------------------------------
# A node pruned with `pruning-keep-recent = 100` (ENGINEERING.md §9.2 validator
# profile) answers eth_getBalance at block 1 with an error once it is past
# height ~100; an archive node (`pruning = "nothing"`) answers at every height.
if [ "$head_dec" -lt 2 ]; then
  note "chain is at block $head_dec; archive check at block 1 is trivially true — re-run later"
fi
body=$(rpc "$RPC_HTTP_URL" eth_getBalance "[\"$ARCHIVE_PROBE_ADDRESS\",\"0x1\"]") || fail "eth_getBalance failed"
if ! has_result "$body"; then
  fail "eth_getBalance at block 1 has no result — this is a PRUNED node, not an archive node (§5.2). Point the explorer at an archive node with pruning = \"nothing\". Response: $(error_message "$body")"
fi
ok "eth_getBalance at block 1 answered — historical state is available"

# also make sure the block itself is served (a node that state-synced from a
# snapshot has no early blocks either)
body=$(rpc "$RPC_HTTP_URL" eth_getBlockByNumber '["0x1", false]') || fail "eth_getBlockByNumber failed"
has_result "$body" || fail "eth_getBlockByNumber(1) has no result — early blocks missing (state-synced node?): $(error_message "$body")"
ok "eth_getBlockByNumber(1) answered — early blocks are available"

# ---- 3. debug namespace ----------------------------------------------------
body=$(rpc "$RPC_TRACE_URL" debug_traceBlockByNumber "[\"$head_hex\", {\"tracer\":\"callTracer\"}]") || fail "cannot reach $RPC_TRACE_URL"
code=$(error_code "$body")
if [ "$code" = "-32601" ]; then
  fail "debug_traceBlockByNumber is not available on $RPC_TRACE_URL — the debug namespace is off. Start the node with --json-rpc.api including 'debug' (app.toml [json-rpc] api)."
fi
# an empty block traces to [] which is still a result
printf '%s' "$body" | grep -q '"result":' || fail "debug_traceBlockByNumber($head_hex) errored: $(error_message "$body")"
ok "debug_traceBlockByNumber works on $RPC_TRACE_URL"

# find a real tx to trace, unless one was given
if [ -z "$TRACE_TX_HASH" ]; then
  i=$head_dec
  stop=$((head_dec - 50)); [ "$stop" -lt 0 ] && stop=0
  while [ "$i" -ge "$stop" ] && [ -z "$TRACE_TX_HASH" ]; do
    body=$(rpc "$RPC_HTTP_URL" eth_getBlockByNumber "[\"$(printf '0x%x' "$i")\", false]") || break
    TRACE_TX_HASH=$(printf '%s' "$body" | sed -n 's/.*"transactions":[[:space:]]*\[[[:space:]]*"\(0x[0-9a-fA-F]\{64\}\)".*/\1/p' | head -n 1)
    i=$((i - 1))
  done
fi

if [ -n "$TRACE_TX_HASH" ]; then
  body=$(rpc "$RPC_TRACE_URL" debug_traceTransaction "[\"$TRACE_TX_HASH\", {\"tracer\":\"callTracer\"}]") || fail "debug_traceTransaction request failed"
  code=$(error_code "$body")
  [ "$code" = "-32601" ] && fail "debug_traceTransaction is not available on $RPC_TRACE_URL"
  has_result "$body" || fail "debug_traceTransaction($TRACE_TX_HASH) errored: $(error_message "$body")"
  ok "debug_traceTransaction traced $TRACE_TX_HASH"
else
  # no tx in the last 50 blocks: prove the method exists — a registered method
  # answers a bogus hash with a lookup error, an unregistered one with -32601
  zero="0x0000000000000000000000000000000000000000000000000000000000000000"
  body=$(rpc "$RPC_TRACE_URL" debug_traceTransaction "[\"$zero\", {\"tracer\":\"callTracer\"}]") || fail "debug_traceTransaction request failed"
  code=$(error_code "$body")
  [ "$code" = "-32601" ] && fail "debug_traceTransaction is not available on $RPC_TRACE_URL"
  note "no transaction in the last 50 blocks to trace; debug_traceTransaction is registered (set TRACE_TX_HASH to trace a real one)"
fi

# ---- 4. websocket ----------------------------------------------------------
if [ -n "$RPC_WS_URL" ]; then
  http_url=$(printf '%s' "$RPC_WS_URL" | sed 's#^ws://#http://#; s#^wss://#https://#')
  status=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "$http_url" 2>/dev/null || true)
  [ "$status" = "101" ] || fail "no WebSocket upgrade at $RPC_WS_URL (HTTP $status). Blockscout needs ws for newHeads; check [json-rpc] ws-address and ws-origins in app.toml."
  ok "WebSocket upgrade accepted at $RPC_WS_URL"
else
  note "RPC_WS_URL not set; skipping WebSocket check"
fi

# ---- informational ---------------------------------------------------------
body=$(rpc "$RPC_HTTP_URL" txpool_status '[]') || true
if [ "$(error_code "$body")" = "-32601" ]; then
  note "txpool namespace is off — pending-transaction display will be empty (INDEXER_DISABLE_PENDING_TRANSACTIONS_FETCHER=true is set for that reason)"
else
  ok "txpool namespace available"
fi

printf 'check-rpc: PASS — %s is an archive node with tracing for chain %s\n' "$RPC_HTTP_URL" "$CHAIN_ID"
