#!/bin/bash
# Cron entry point for the daily incremental sync (ported from the Python
# project's run_daily_sync.sh). Runs the built oura-daily-sync executable and
# appends output to a log file.

export PATH=$HOME/.local/bin:$PATH

WORK_DIR=$HOME/work/oura-dashboard-hs

cd "$WORK_DIR" || exit 1
mkdir -p "$WORK_DIR/log"

# Prefer the installed binary; fall back to `stack exec` if not installed.
BIN="$(stack path --local-install-root 2>/dev/null)/bin/oura-daily-sync"
if [ -x "$BIN" ]; then
    "$BIN" >> "$WORK_DIR/log/oura-daily-sync.log" 2>&1
else
    stack exec oura-daily-sync >> "$WORK_DIR/log/oura-daily-sync.log" 2>&1
fi
