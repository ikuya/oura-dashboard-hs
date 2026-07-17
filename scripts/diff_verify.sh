#!/usr/bin/env bash
# Phase 8 diff verification: run the Python (Flask) and Haskell (Yesod) apps
# against the SAME copy of oura.db and diff their JSON API responses.
#
# This is a throwaway acceptance check, not part of CI. It surfaces byte-level
# contract differences the unit tests can't (key order, number formatting like
# 80 vs 80.0, non-ASCII escaping).
#
# Usage: scripts/diff_verify.sh
# Requires: the Python app in ../oura-dashboard with its venv, curl, jq, python3.

set -uo pipefail

HS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PY_DIR="$HS_DIR/../oura-dashboard"
WORK="$(mktemp -d)"
DB_SRC="$PY_DIR/oura.db"
PY_PORT=5055
HS_PORT=3055
PW="diff-verify-password"

cleanup() {
    [ -n "${PY_PID:-}" ] && kill "$PY_PID" 2>/dev/null
    [ -n "${HS_PID:-}" ] && kill "$HS_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# Two independent copies so each app's startup migrations don't interfere.
cp "$DB_SRC" "$WORK/py.db"
cp "$DB_SRC" "$WORK/hs.db"

# Shared secret material.
SECRET_KEY="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"
PY_HASH="$(cd "$PY_DIR" && .venv/bin/python -c "from werkzeug.security import generate_password_hash as g;print(g('$PW'))")"

# Generate the bcrypt hash via a temp .hs file (runghc doesn't accept `-` stdin).
GENHS="$WORK/genhash.hs"
cat > "$GENHS" <<EOF
import Crypto.BCrypt
import Data.ByteString.Char8 (pack, unpack)
main = hashPasswordUsingPolicy slowerBcryptHashingPolicy (pack "$PW") >>= putStrLn . maybe "FAIL" unpack
EOF
HS_HASH="$(cd "$HS_DIR" && stack runghc --package bcrypt -- "$GENHS" 2>/dev/null | tail -1)"

# --- Start Python app ---
( cd "$PY_DIR" && \
  OURA_TOKEN=x SECRET_KEY="$SECRET_KEY" APP_PASSWORD="$PY_HASH" \
  DB_PATH="$WORK/py.db" \
  .venv/bin/python -c "
import os, db
db.DB_PATH = '$WORK/py.db'
import app
app.app.run(port=$PY_PORT)
" ) &
PY_PID=$!

# --- Start Haskell app ---
HS_BIN="$(cd "$HS_DIR" && stack path --local-install-root)/bin/oura-dashboard-hs"
( cd "$HS_DIR" && \
  YESOD_SQLITE_DATABASE="$WORK/hs.db" YESOD_PORT=$HS_PORT \
  OURA_TOKEN=x SECRET_KEY="$SECRET_KEY" APP_PASSWORD="$HS_HASH" \
  "$HS_BIN" ) &
HS_PID=$!

# Wait for both to accept connections.
for port in $PY_PORT $HS_PORT; do
    for i in $(seq 1 30); do
        curl -s -o /dev/null "http://localhost:$port/" && break
        sleep 1
    done
done

PY_CK="$WORK/py.ck"; HS_CK="$WORK/hs.ck"
curl -s -c "$PY_CK" -X POST "http://localhost:$PY_PORT/api/login" \
     -H 'Content-Type: application/json' -d "{\"password\":\"$PW\"}" >/dev/null
curl -s -c "$HS_CK" -X POST "http://localhost:$HS_PORT/api/login" \
     -H 'Content-Type: application/json' -d "{\"password\":\"$PW\"}" >/dev/null

# Endpoints to compare (GET only; deterministic against a fixed DB).
ENDPOINTS=(
    "/api/sync/status"
    "/api/metrics?metric=sleep,readiness,activity,stress,spo2,resilience,cardiovascular_age,temperature&start=2024-06-01&end=2024-06-30"
    "/api/metrics/sleep?start=2024-06-01&end=2024-06-30"
    "/api/heartrate?start=2024-06-01&end=2024-06-07"
    "/api/advice/history"
)

# Canonicalize: sort keys, and normalize numbers so 84.0 == 84 (SQLite REAL
# columns render as floats in Python but as ints in aeson when whole; the values
# are numerically identical and the frontend treats them the same).
NORM='def n: if type=="number" then (.*1000|round/1000) else . end;
      walk(n)'

FAILED=0
for ep in "${ENDPOINTS[@]}"; do
    py="$(curl -s -b "$PY_CK" "http://localhost:$PY_PORT$ep" | jq -S "$NORM")"
    hs="$(curl -s -b "$HS_CK" "http://localhost:$HS_PORT$ep" | jq -S "$NORM")"
    if [ "$py" = "$hs" ]; then
        echo "OK    $ep"
    else
        echo "DIFF  $ep"
        diff <(echo "$py") <(echo "$hs") | head -40
        FAILED=1
    fi
done

exit $FAILED
