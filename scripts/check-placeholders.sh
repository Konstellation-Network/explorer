#!/bin/sh
# CI guard for the placeholder env files (.env.testnet-1, .env.konstellation-1):
# every value that must stay a placeholder until infra exists is checked in
# the RENDERED compose config (`docker compose config --format json`), so
# `export KEY=…`, leading whitespace, a `TODO` in a comment or a value like
# `real=TODO` cannot slip past. Secrets must be exactly `TODO`; hosts must
# start with `TODO-`.
#
# Also, for each file: the dev-only `local-s3` profile must be off (no
# `minio` service rendered), and it warns loudly when the proxy is
# published beyond loopback (EXPLORER_BIND) with no TRUSTED_INGRESS_CIDR —
# in that layout every client's X-Forwarded-For is replaced, which is safe,
# but usually means the ingress was forgotten.
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
redis-db                  REDIS_PASSWORD                          secret
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

  # dev-only profile must not be on for a real network
  if printf '%s' "$rendered" | jq -e '.services.minio' >/dev/null 2>&1; then
    echo "  FAIL the local-s3 profile (MinIO stand-in) is enabled — COMPOSE_PROFILES in $envfile must not include local-s3"
    status=1
  else
    echo "  ok   local-s3 profile off"
  fi

  # deploy-time sanity on exposure
  bind=$(printf '%s' "$rendered" | jq -r '.services.proxy.ports[0].host_ip // "0.0.0.0"')
  cidr=$(printf '%s' "$rendered" | jq -r '.services.proxy.environment.TRUSTED_INGRESS_CIDR // ""')
  if [ "$bind" != "127.0.0.1" ] && { [ -z "$cidr" ] || [ "$cidr" = "0.0.0.0/32" ]; }; then
    echo "  WARN proxy is published on $bind (EXPLORER_BIND) but TRUSTED_INGRESS_CIDR is empty: no ingress is trusted, so"
    echo "       every client's X-Forwarded-For is replaced by its own address — fine without an ingress, wrong behind one."
    echo "       Set TRUSTED_INGRESS_CIDR to the ingress's source range, or EXPLORER_BIND=127.0.0.1 with the ingress on this host."
  else
    echo "  ok   proxy bind $bind, trusted ingress ${cidr}"
  fi
done
exit $status
