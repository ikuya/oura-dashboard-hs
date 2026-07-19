#!/bin/bash
# Cron entry point for the daily incremental sync (ported from the Python
# project's run_daily_sync.sh). Runs the built oura-daily-sync executable and
# appends output to a log file.

export PATH=$HOME/.ghcup/bin:$HOME/.local/bin:$PATH

WORK_DIR=$HOME/work/oura-dashboard-hs

cd "$WORK_DIR" || exit 1
mkdir -p "$WORK_DIR/log"

# The app writes its own log here. Rotation is handled by logrotate; see README.
export LOG_FILE="$WORK_DIR/log/oura-daily-sync.log"

# Anything the app cannot log itself (startup crashes, RTS errors) goes to a
# separate file, so the two writers never share one handle.
STDIO_LOG="$WORK_DIR/log/oura-daily-sync.stdio.log"

# Prefer the installed binary; fall back to `stack exec` if not installed.
BIN="$(stack path --local-install-root 2>/dev/null)/bin/oura-daily-sync"
if [ -x "$BIN" ]; then
    "$BIN" >> "$STDIO_LOG" 2>&1
else
    stack exec oura-daily-sync >> "$STDIO_LOG" 2>&1
fi
