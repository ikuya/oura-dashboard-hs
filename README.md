# oura-dashboard-hs

A Haskell/Yesod port of [oura-dashboard](../oura-dashboard): a local web dashboard
for Oura Ring biometric data. Fetches data from the Oura Ring API v2 into a local
SQLite database and serves an existing static frontend (Chart.js) over a JSON API.

The JSON API is byte-compatible with the Python/Flask original, so the same
`static/` frontend runs unchanged.

## Features

- Overview dashboard: Sleep, Readiness, Activity, Stress, SpO2, Temperature,
  Heart Rate, Resilience, VO2 Max, Cardiovascular Age
- Incremental sync (only fetches dates not yet stored locally)
- **Advice** — analyzes the last 14 days with the `claude` CLI and shows a
  Japanese health summary; saved to the DB and browsable
- **Password protection** — session-based, password stored as a bcrypt hash in
  `APP_PASSWORD`
- Fully local: no external services beyond the Oura API and Claude CLI

## Setup

Requires [Stack](https://get.haskellstack.org/). The first build downloads GHC
8.10.7 (per `stack.yaml`'s `lts-18.28`) and compiles the dependency tree — this
takes a while; subsequent builds are fast.

```bash
stack build
```

Create a `.env` in the project directory:

```bash
echo "OURA_TOKEN=your_token_here" > .env
echo "SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')" >> .env
```

Set `APP_PASSWORD` to a **bcrypt** hash of your password. Generate one with the
bundled dependency:

```bash
stack runghc --package bcrypt -- - <<'EOF'
import Crypto.BCrypt
import Data.ByteString.Char8 (pack, unpack)
main = hashPasswordUsingPolicy slowerBcryptHashingPolicy (pack "your_password")
       >>= putStrLn . maybe "FAIL" unpack
EOF
```

Then add it to `.env` **in single quotes** (bcrypt hashes contain `$`, which the
dotenv parser would otherwise treat as variable interpolation and crash at
startup):

```
APP_PASSWORD='$2y$14$....'
```

## Getting an Oura Access Token

1. Visit https://cloud.ouraring.com/personal-access-tokens (login required)
2. Create a new Personal Access Token and copy it into `OURA_TOKEN`.

> API access requires an active Oura Membership.

## Running

```bash
stack exec oura-dashboard-hs
```

Then open http://localhost:3000 (override with `YESOD_PORT`). The database path
defaults to `oura.db` (override with `YESOD_SQLITE_DATABASE`).

During development, `stack exec -- yesod devel` gives auto-reload.

## Daily Automatic Sync

The `oura-daily-sync` executable runs an incremental sync and backfills missing
days within the last 7 days:

```bash
stack exec oura-daily-sync
```

Wire it into cron via `run_daily_sync.sh` (runs a few times a day so intraday
heart-rate data stays current).

## Tests

```bash
stack test
```

## Project layout

```
config/models.persistentmodels   Persistent models mapped onto the existing oura.db schema
config/routes.yesodroutes         Route definitions
config/settings.yml               Settings (secrets sourced from .env)
src/Db.hs                         SQLite query/upsert layer (ported from db.py)
src/Oura.hs                       Oura Ring API v2 client (record of fetch functions)
src/Sync.hs                       Incremental sync logic (ported from sync.py)
src/Advice.hs                     Advice job state + claude CLI worker
src/Foundation.hs                 App foundation, session auth (bcrypt)
src/Handler/Api.hs                Auth + metrics/heartrate/sync handlers
src/Handler/Advice.hs             Advice endpoints
src/Handler/Home.hs               Serves static/index.html
app/main.hs                       Web server entry point
static/                           Existing frontend (index.html, *.js, style.css)
```

See `MIGRATION_PLAN.md` for the design decisions behind the port.
