# explorer

Blockscout deployment config for Konstellation (`ENGINEERING.md §6.5`). One
`docker-compose.yml`, one env file per network, no code. This repo produces
configuration only; the binary it explores comes from `konstellation`.

```
explorer/
├── docker-compose.yml        # backend, frontend, postgres ×2, redis, stats,
│                             # smart-contract-verifier, user-ops-indexer,
│                             # nft-media-handler, nginx; `local-s3` profile
├── .env.local                # dev chain, EIP-155 56670 — real, runnable values
├── .env.testnet-1            # 56671 — PLACEHOLDERS (TODO) until infra exists
├── .env.konstellation-1      # 5667  — PLACEHOLDERS (TODO) until infra exists
├── envs/*.common.env         # per-service settings shared by every network
├── nginx/default.conf.template
├── branding/                 # logo (placeholder), icon (placeholder), KASH metadata
├── scripts/check-rpc.sh      # archive-node + debug-namespace preflight
└── .github/workflows/ci.yml  # compose config per env, pins, shellcheck, preflight test
```

## The archive-node dependency

Blockscout indexes internal transactions with `debug_traceTransaction` /
`debug_traceBlockByNumber` and fetches balances at historical heights. It
therefore needs an **archive node with tracing enabled**, never a pruned RPC
(`ENGINEERING.md §5.2`, §6.5, §9.2). On a Konstellation node that means:

| Setting | Value | Where |
|---|---|---|
| `pruning` | `"nothing"` | `app.toml` (`infra` ansible group `archive`) |
| `[json-rpc] api` | includes `debug` (and `txpool`) | `app.toml`; `infra` sets it when `evm_tracer_enabled: true` |
| `[json-rpc] enable` | `true`; `address` / `ws-address` reachable from the explorer host | `app.toml` — **`infra` leaves the default `127.0.0.1` bind; the archive playbook must set these to the private-network address before the explorer can connect** |
| network exposure | private only — archive nodes are not public (§9.2) | terraform / firewall |

`scripts/check-rpc.sh` enforces this. It runs as the `rpc-preflight` service
before the backend starts and refuses (exit 1) unless the target answers
`eth_chainId` with the expected id, serves `eth_getBalance` and
`eth_getBlockByNumber` at block 1, exposes `debug_traceBlockByNumber` and
`debug_traceTransaction`, and accepts a WebSocket upgrade. Run it by hand
against any RPC:

```bash
RPC_HTTP_URL=http://127.0.0.1:8545 RPC_WS_URL=ws://127.0.0.1:8546 CHAIN_ID=56670 scripts/check-rpc.sh
```

Pointing the explorer at a pruned node "works" for a few hundred blocks and
then the internal-transaction fetcher stalls forever. Do not set
`ETHEREUM_JSONRPC_DISABLE_ARCHIVE_BALANCES=true` to paper over it; swap the node.

## Run locally against the dev chain

```bash
# 1. dev chain (already an archive node with debug on: local_node.sh passes
#    --pruning nothing and --json-rpc.api eth,txpool,personal,net,debug,web3)
cd ~/Desktop/Konstellation-Network/konstellation
./local_node.sh -y                 # JSON-RPC :8545, ws :8546, chain id 56670

# 2. explorer
cd ~/Desktop/Konstellation-Network/explorer
docker compose --env-file .env.local up -d
docker compose --env-file .env.local logs -f rpc-preflight backend
```

Then open http://localhost:3080 (stats API on :3081). The backend reaches the
node at `host.docker.internal:8545`, which Docker Desktop maps to the host's
loopback. On Linux `host.docker.internal` resolves to the bridge gateway, so a
node bound to `127.0.0.1` is *not* reachable — either set `[json-rpc]
address = "0.0.0.0:8545"` / `ws-address = "0.0.0.0:8546"` in
`~/.konstellationd/config/app.toml` or run the node inside the compose network.

Stop with `docker compose --env-file .env.local down` (add `-v` to drop the
indexed database — required after `local_node.sh -y`, which is a new chain
with the same id; the explorer cannot tell and will serve stale blocks).

Ports 3080/3081 were picked to stay clear of the node's 8545/8546 and of
anything privileged. Change `EXPLORER_PORT`/`STATS_PORT` (and the matching
`*_PUBLIC_*` values) in `.env.local` if they collide.

## Deploy to testnet-1 / konstellation-1

1. `infra` provisions the network's archive node (terraform `archive` module,
   ansible group `archive`) and its private DNS name. Until then every host in
   `.env.testnet-1` / `.env.konstellation-1` is a `TODO` and CI checks that
   they stay that way.
2. Fill the `TODO`s **in the deployment platform's env/secret store** (Coolify
   or k8s — `ENGINEERING.md §9.1` puts the stateless app tier there), not in
   git. Secrets: `openssl rand -base64 48` for `POSTGRES_PASSWORD`,
   `STATS_POSTGRES_PASSWORD`, `SECRET_KEY_BASE`. The committed file stays the
   documented shape; the platform overrides values.
3. `docker compose --env-file .env.<net> config` locally to check the render,
   then `up -d`. The preflight refuses to start the backend against the wrong
   chain id or a non-archive node, so a mis-pointed deploy fails loudly.
4. TLS terminates at the platform ingress; the `proxy` container serves plain
   HTTP on `EXPLORER_PORT` (frontend + API on one origin) and `STATS_PORT`.
   The frontend needs to know its public origin (`EXPLORER_HOST`,
   `EXPLORER_PROTOCOL`, `EXPLORER_PUBLIC_URL`, `STATS_PUBLIC_URL`).

## What is configured

- **Chain**: name "Konstellation", currency KASH / 18 decimals (`envs/*.common.env`,
  `branding/token-metadata.json`), `CHAIN_ID` per env file (`ENGINEERING.md §1`).
- **RPC**: `ETHEREUM_JSONRPC_VARIANT=geth` (cosmos/evm exposes the geth
  dialect, §7.1), separate `ETHEREUM_JSONRPC_TRACE_URL` so a dedicated trace
  endpoint can be used later, `ETHEREUM_JSONRPC_WS_URL` for `newHeads`,
  per-transaction tracing (`ETHEREUM_JSONRPC_GETH_TRACE_BY_BLOCK=false` —
  cosmos/evm's `debug_traceBlockByNumber` lacks the per-entry `txHash`
  Blockscout's block-level parser needs; see `envs/backend.common.env`).
- **Indexer**: batch sizes and concurrency lowered for a low-throughput chain
  (`envs/backend.common.env`, each knob commented). Block-reward, withdrawal,
  and pending-tx fetchers are off (no EVM-side rewards — issuance is `x/mint`;
  no beacon withdrawals; the Krakatoa mempool's `txpool_*` is unverified against
  Blockscout — re-enable pending txs once it is).
- **ERC-4337**: `user-ops-indexer` with EntryPoint **v0.7** and **v0.8** at the
  preinstalled canonical addresses (`contracts/preinstalls/EntryPointV0{7,8}.json`),
  v0.6 off; the backend and frontend have the account-abstraction views on.
- **Verification**: `smart-contract-verifier` (solc + vyper), run as
  `linux/amd64` on every host (the solc binaries it downloads are amd64; a
  native arm64 container cannot exec them) with `verifier-init` chowning the
  compiler volumes to its uid 1001 (fresh volumes are root-owned and every
  download failed). Sourcify is off — it does not know the chain. Proven with
  `forge verify-contract --verifier blockscout --verifier-url
  http://localhost:3080/api --chain-id 56670` on WKASH: `Pass - Verified`,
  partial match (its bytecode is metadata-stripped).
- **NFT media**: see below.
- **Not run** (upstream's compose has them; dropped to keep the footprint small):
  `visualizer` (sol2uml), `sig-provider`, `nft_media_handler`, Blockscout
  accounts/auth0, market data (KASH has no listing; `DISABLE_MARKET=true`).

## NFT media

Blockscout shows NFT images two ways: the frontend loads the token's own
`image` URL, and — when the media handler is on — the backend serves resized
copies (60/250/500 px, sizes hardcoded upstream) from object storage, so a
listing page never hits fifty random hosts. The handler is the
`nft-media-handler` service: the backend image started as a standalone
worker that talks to the backend over Erlang distribution (fixed IPs on the
compose network, `RELEASE_COOKIE` shared) and uploads to an
**S3-compatible bucket over HTTPS** — scheme and port are hardcoded in 9.0.2,
so the target is Cloudflare R2, AWS S3 or anything with an S3 API behind TLS,
with anonymous reads on `NFT_MEDIA_S3_PUBLIC_URL` (bucket or CDN).
Settings and their rationale: `envs/nft-media.common.env`; per network:
`NFT_MEDIA_S3_*`, `IPFS_GATEWAY_URL`, `RELEASE_COOKIE` in `.env.<net>`.

Locally the `local-s3` profile (on in `.env.local` via `COMPOSE_PROFILES`)
stands in for the bucket: MinIO on `https://minio:443` with a self-signed
cert generated once into a volume, an init job that creates the bucket with
anonymous read, and `local-s3-proxy` on http://localhost:3082 so the browser
can load thumbnails without trusting that cert. The worker accepts the
self-signed cert through `NFT_MEDIA_S3_ERL_OPTIONS` (`-ex_aws hackney_opts
[insecure,...]`, the one knob the release leaves open). Verified 2026-09-20
with a scratch ERC-721 (three tokens: two https PNGs, one `ipfs://` PNG):
metadata indexed, thumbnails generated and served, instance pages render.

Two upstream limitations recorded in `docker-compose.yml`: the backend's
"in progress" media table is persisted and never expires, so it is dropped on
every start (the backfiller re-queues anything without thumbnails); and
`ipfs.io` throttles unauthenticated bursts (429) — `.env.local` uses
pinata's public gateway, real networks should use a paid/pinning gateway.
Thumbnails are served as `application/octet-stream` (the uploader sets no
content type; browsers sniff images fine).

## Versions

Every image is pinned by tag **and** digest (`ENGINEERING.md §2.3`). CI fails
on any `image:` without a digest or with `latest`.

| Service | Image | Note |
|---|---|---|
| backend | `ghcr.io/blockscout/blockscout:9.0.2` | **newest tag in the public registry** (2025-08-14). Upstream source is at v11.3.1, but v10/v11 images are pushed only to `ghcr.io/blockscout/blockscout-private`; the manual `public-release.yml` copy has not run since 9.0.2. Options when a newer backend is needed: build from the release tag with upstream's `docker/Dockerfile` and push to our own registry, or wait for a public copy. Check before bumping: `docker manifest inspect ghcr.io/blockscout/blockscout:<tag>`. |
| frontend | `ghcr.io/blockscout/frontend:v2.3.5` | same situation: newest public tag (2025-10-14); v2.4+ are private. Env names used here are verified against `docs/ENVS.md` at that tag. |
| stats | `ghcr.io/blockscout/stats:v2.19.1` | current |
| smart-contract-verifier | `ghcr.io/blockscout/smart-contract-verifier:v1.10.7` | current |
| user-ops-indexer | `ghcr.io/blockscout/user-ops-indexer:v1.4.3` | current; supports EntryPoint v0.8 |
| postgres | `postgres:17.6-alpine` | upstream uses `postgres:17` |
| redis | `redis:7.4-alpine` | |
| nginx | `nginx:1.28-alpine` | |
| preflight | `curlimages/curl:8.14.1` | |
| verifier-init | `alpine:3.22.2` | chowns the compiler volumes |
| local-s3 (profile) | `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`, `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z`, `alpine/openssl:3.5.4` | dev only |

To bump: change the tag, `docker buildx imagetools inspect <image:tag>` for the
new digest, run `docker compose --env-file .env.local up -d` against the dev
chain and watch it index, then commit with both in the message.

## Placeholders — what is not real yet

- All `TODO-*` hostnames in `.env.testnet-1` and `.env.konstellation-1`
  (archive RPC, public RPC, explorer and stats hostnames) and their secrets.
- `branding/logo.svg` and `branding/icon.svg` are SVG text marks; a real logo
  is needed before testnet-1 is public (`branding/README.md`).
- The frontend colour palette in `envs/frontend.common.env` is a neutral
  placeholder.
- `NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID` is unset, so "add network to
  wallet" / write-contract buttons stay hidden.
- NFT media bucket (`NFT_MEDIA_S3_*`) and `RELEASE_COOKIE` for testnet-1 /
  mainnet — need real object storage.

## Secrets

`.env.local` carries dev-only credentials on purpose (the dev chain's own
mnemonics are public too). The other env files carry `TODO` and CI refuses a
real value in the three secret keys. `.env.*.secrets` is git-ignored if you
want a local override file; pass it as a second `--env-file`.
