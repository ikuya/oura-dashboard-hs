#!/usr/bin/zsh

export PATH=$HOME/.ghcup/bin:$PATH

WORK_DIR=$HOME/work/oura-dashboard-hs

cd "$WORK_DIR" || exit 1
mkdir -p "$WORK_DIR/log"

# The app writes its own log here. Rotation is handled by logrotate; see README.
export LOG_FILE="$WORK_DIR/log/oura-dashboard.log"

# Request (Apache-format) lines go to their own file; the app's own lines, which
# use a different timestamp format, stay in LOG_FILE.
export ACCESS_LOG_FILE="$WORK_DIR/log/oura-dashboard.access.log"

# Anything the app cannot log itself (startup crashes, RTS errors) goes to a
# separate file rather than nohup.out, so the two writers never share one handle.
nohup stack exec oura-dashboard-hs >> "$WORK_DIR/log/oura-dashboard.stdio.log" 2>&1 &

