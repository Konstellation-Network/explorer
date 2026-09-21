#!/bin/sh
# CI guard for the placeholder env files (.env.testnet-1, .env.konstellation-1):
# every value that must stay a placeholder until infra exists is checked in
# the RENDERED compose config (`docker compose config --format json`), so
# `export KEY=…`, leading whitespace, a `TODO` in a comment or a value like
# `real=TODO` cannot slip past. Secrets must be exactly `TODO`; hosts must
# start with `TODO-`.
#
# Usage: scripts/check-placeholders.sh .env.testnet-1 [.env.konstellation-1 ...]
set -eu

command -v jq >/dev/null 2>&1 || { echo "check-placeholders: jq required" >&2; exit 2; }

# service  env-key                              rule
CHECKS='
db                        POSTGRES_PASSWORD                       secret
stats-db                  POSTGRES_PASSWORD                       secret
backend                   SECRET_KEY_BASE                         secret
backend                   RELEASE_COOKIE                          secret-or-empty
backend                   NFT_MEDIA_HANDLER_AWS_ACCESS_KEY_ID     secret-or-empty
backend                   NFT_MEDIA_HANDLER_AWS_SECRET_ACCESS_KEY secret-or-empty
backend                   NFT_MEDIA_HANDLER_AWS_BUCKET_HOST       host-or-empty
backend                   NFT_MEDIA_HANDLER_AWS_PUBLIC_BUCKET_URL url-or-empty
rpc-preflight             RPC_HTTP_URL                            url
rpc-preflight             RPC_TRACE_URL                           url
rpc-preflight             RPC_WS_URL                              url
frontend                  NEXT_PUBLIC_NETWORK_RPC_URL             url
frontend                  NEXT_PUBLIC_API_HOST                    host
frontend                  NEXT_PUBLIC_STATS_API_HOST              url
backend                   BLOCKSCOUT_HOST                         host
'

status=0
for envfile in "$@"; do
  rendered=$(docker compose --env-file "$envfile" config --format json)
  echo "== $envfile"
  printf '%s\n' "$CHECKS" | while read -r svc key rule; do
    [ -n "$svc" ] || continue
    val=$(printf '%s' "$rendered" | jq -r --arg s "$svc" --arg k "$key" '.services[$s].environment[$k] // "" | tostring')
    okv=0
    case "$rule" in
      secret)           [ "$val" = "TODO" ] && okv=1 ;;
      secret-or-empty)  { [ "$val" = "TODO" ] || [ -z "$val" ]; } && okv=1 ;;
      host)             case "$val" in TODO-*) okv=1 ;; esac ;;
      host-or-empty)    case "$val" in TODO-*|"") okv=1 ;; esac ;;
      # a URL placeholder is scheme://TODO-... (any port/path after)
      url)              case "$val" in *://TODO-*) okv=1 ;; esac ;;
      url-or-empty)     case "$val" in *://TODO-*|"") okv=1 ;; esac ;;
    esac
    if [ "$okv" = 1 ]; then
      printf '  ok   %-14s %-40s %s\n' "$svc" "$key" "$rule"
    else
      printf '  FAIL %-14s %-40s rendered as %s — must be a placeholder (%s). Real values go in the deployment secret store, not git.\n' "$svc" "$key" "'$val'" "$rule"
      exit 1
    fi
  done || status=1
done
exit $status
