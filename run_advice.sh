#!/bin/bash
# Cron entry point for the scheduled advice (Mon/Wed/Fri, after the morning
# sync). Runs the built oura-advice executable and appends output to a log file.

# ~/.local/bin holds the claude CLI the advice is generated with.
export PATH=$HOME/.ghcup/bin:$HOME/.local/bin:$PATH

# Long-lived subscription token from `claude setup-token`, kept outside the
# repo (mode 600). It replaces the interactive /login session, which can
# expire and break unattended runs.
TOKEN_FILE=$HOME/.config/oura-dashboard/claude-token.env
if [ -r "$TOKEN_FILE" ]; then
    set -a
    . "$TOKEN_FILE"
    set +a
fi
# An API key would take precedence and bill the API instead of the plan.
unset ANTHROPIC_API_KEY

WORK_DIR=$HOME/work/oura-dashboard-hs

cd "$WORK_DIR" || exit 1
mkdir -p "$WORK_DIR/log"

# The app writes its own log here. Rotation is handled by logrotate; see README.
export LOG_FILE="$WORK_DIR/log/oura-advice.log"

# Anything the app cannot log itself (startup crashes, RTS errors) goes to a
# separate file, so the two writers never share one handle.
STDIO_LOG="$WORK_DIR/log/oura-advice.stdio.log"

# Prefer the installed binary; fall back to `stack exec` if not installed.
BIN="$(stack path --local-install-root 2>/dev/null)/bin/oura-advice"
if [ -x "$BIN" ]; then
    "$BIN" >> "$STDIO_LOG" 2>&1
else
    stack exec oura-advice >> "$STDIO_LOG" 2>&1
fi
