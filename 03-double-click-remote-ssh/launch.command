#!/bin/bash
# Double-click launcher for the devx-remote-ssh sandbox.
# Runs start.sh, opens VSCode, then closes this Terminal window on success.
# If start.sh fails, the window stays open so you can read the error.

set -e
cd "$(dirname "$0")"

# Remember the Terminal window we're running in so we can close just this one.
WINDOW_ID="$(osascript -e 'tell application "Terminal" to id of front window' 2>/dev/null || true)"

./start.sh

if [ -n "$WINDOW_ID" ]; then
  # Spawn osascript in a brand-new session (setsid) so it leaves this
  # Terminal window's TTY. Once bash exits, the window has no attached
  # processes and Terminal closes it without prompting.
  /usr/bin/perl -e '
    use POSIX qw(setsid);
    fork and exit;            # parent returns to bash
    POSIX::setsid();           # detach from controlling TTY
    fork and exit;             # avoid reacquiring a TTY
    exec @ARGV;
  ' /usr/bin/osascript \
    -e "delay 1" \
    -e "tell application \"Terminal\" to close (every window whose id is ${WINDOW_ID})" \
    </dev/null >/dev/null 2>&1
fi
