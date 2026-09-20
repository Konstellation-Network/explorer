# branding/

Everything the explorer shows that is *ours* rather than Blockscout's. The nginx
proxy serves this directory at `/branding/` (see `nginx/default.conf.template`),
and the frontend is pointed at it through `NEXT_PUBLIC_NETWORK_LOGO` /
`NEXT_PUBLIC_NETWORK_ICON` in `docker-compose.yml`.

| File | Used for | Status |
|---|---|---|
| `logo.svg` | header logo (frontend `NEXT_PUBLIC_NETWORK_LOGO`; ideally ≤ 240×48, transparent) | **PLACEHOLDER** — an SVG text mark. A real logo is needed before testnet-1 goes public. |
| `icon.svg` | favicon / compact mark (`NEXT_PUBLIC_NETWORK_ICON`; square) | **PLACEHOLDER** — same. |
| `token-metadata.json` | KASH name, symbol, decimals, base denom, chain ids — for the explorer envs and for `chain-config` / wallet listings to copy from | real values (ENGINEERING.md §1, D2) |

## Colours

The frontend's colour tokens live in `envs/frontend.common.env`
(`NEXT_PUBLIC_COLOR_THEME_DEFAULT`, `NEXT_PUBLIC_HOMEPAGE_HERO_BANNER_CONFIG`). The current
values are a neutral dark-blue placeholder palette (`#0b1020` → `#1c2a5a`,
accent `#7aa2ff`, text `#f4f6fb`), chosen only so the placeholder logo is
legible. When the brand is decided, change them there and keep this note in
sync. Blockscout frontend v2.3 also accepts a dark-mode logo/icon
(`NEXT_PUBLIC_NETWORK_LOGO_DARK`, `NEXT_PUBLIC_NETWORK_ICON_DARK`) — add
`logo-dark.svg` / `icon-dark.svg` here and wire them in `docker-compose.yml`
if the real mark needs them.

## Token metadata

`token-metadata.json` is the one place in this repo that spells out the native
token. It mirrors `ENGINEERING.md §1` and must move with it. `coingeckoId` is
`null` because KASH is not listed anywhere; the backend runs with
`DISABLE_MARKET=true` for that reason. If/when a listing exists, set the id
here and in `envs/backend.common.env` (`EXCHANGE_RATES_COINGECKO_COIN_ID`) and
drop `DISABLE_MARKET`.
