# branding/

Everything the explorer shows that is *ours* rather than Blockscout's. The nginx
proxy serves this directory at `/branding/` (see `nginx/default.conf.template`),
and the frontend is pointed at it through `NEXT_PUBLIC_NETWORK_LOGO` /
`NEXT_PUBLIC_NETWORK_ICON` in `docker-compose.yml`.

| File | Used for | Status |
|---|---|---|
| `logo.svg` | header logo on the light theme (frontend `NEXT_PUBLIC_NETWORK_LOGO`; ideally ≤ 240×48, transparent, dark wordmark) | **PLACEHOLDER** — an SVG text mark. A real logo is needed before devnet-1 goes public. |
| `logo-dark.svg` | the same for the dark theme (`NEXT_PUBLIC_NETWORK_LOGO_DARK`; light wordmark) | **PLACEHOLDER** — same. |
| `icon.svg` | favicon / compact mark (`NEXT_PUBLIC_NETWORK_ICON`; square) | **PLACEHOLDER** — same. |
| `token-metadata.json` | KASH name, symbol, decimals, base denom, chain ids — for the explorer envs and for `chain-config` / wallet listings to copy from | real values (ENGINEERING.md §1, D2) |

## Colours

The frontend's colour tokens live in `envs/frontend.common.env`
(`NEXT_PUBLIC_COLOR_THEME_DEFAULT`, `NEXT_PUBLIC_HOMEPAGE_HERO_BANNER_CONFIG`). The current
values are a neutral dark-blue placeholder palette (`#0b1020` → `#1c2a5a`,
accent `#7aa2ff`, text `#f4f6fb`), chosen only so the placeholder logo is
legible. When the brand is decided, change them there and keep this note in
sync. The dark-theme logo is wired (`NEXT_PUBLIC_NETWORK_LOGO_DARK`); the icon has
its own background so one file serves both themes — add `icon-dark.svg` and
`NEXT_PUBLIC_NETWORK_ICON_DARK` in `docker-compose.yml` if the real mark
needs it.

## Token metadata

`token-metadata.json` is the one place in this repo that spells out the native
token. It mirrors `ENGINEERING.md §1` and must move with it. `coingeckoId` is
`null` because KASH is not listed anywhere; the backend runs with
`DISABLE_MARKET=true` for that reason. If/when a listing exists, set the id
here and in `envs/backend.common.env` (`EXCHANGE_RATES_COINGECKO_COIN_ID`) and
drop `DISABLE_MARKET`.
