#!/usr/bin/env bash
# spawn_visible.sh — run a long command in a terminal the HUMAN can watch,
# while returning immediately so the agent isn't blocked.
#
#   ./spawn_visible.sh python train.py --config configs/a.yaml
#
# Env overrides: RUN_ID, RUN_DIR, SPLIT_PERCENT, FORCE_BACKEND
#
# Emits a KEY=VALUE block on stdout describing where the run is visible.

set -euo pipefail

[ $# -gt 0 ] || { echo "usage: $0 <command...>" >&2; exit 2; }

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RUN_DIR="${RUN_DIR:-.paper-reproduction/runs/$RUN_ID}"
SPLIT_PERCENT="${SPLIT_PERCENT:-45}"
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"          # absolute; spawned terminals may start elsewhere
LOG="$RUN_DIR/console.log"
WRAPPER="$RUN_DIR/_launch.sh"
SESSION="exp-$RUN_ID"

# --- build the wrapper the visible terminal will execute -----------------
# Writing a file avoids nested-quoting hell across the various spawn backends.
{
  echo '#!/usr/bin/env bash'
  echo "cd $(printf '%q' "$PWD")"
  echo 'export PYTHONUNBUFFERED=1 FORCE_COLOR=1'
  echo "export RUN_ID=$(printf '%q' "$RUN_ID") RUN_DIR=$(printf '%q' "$RUN_DIR")"
  echo 'set -o pipefail'
  printf 'printf "\\033]0;%s\\007"\n' "$SESSION"      # title the window
  echo -n 'stdbuf -oL -eL '
  for a in "$@"; do printf '%q ' "$a"; done
  echo "2>&1 | tee $(printf '%q' "$LOG")"
  echo "echo \${PIPESTATUS[0]} > $(printf '%q' "$RUN_DIR/exit_code")"
  echo 'printf "\n=== finished (exit %s) — this pane stays open ===\n" "$(cat '"$(printf '%q' "$RUN_DIR/exit_code")"')"'
  echo 'read -r -p "press enter to close "'
} > "$WRAPPER"
chmod +x "$WRAPPER"

backend=""
attach="-"

try() { command -v "$1" >/dev/null 2>&1; }

# --- detection ladder ----------------------------------------------------
# FORCE_BACKEND=tmux-split|wezterm|kitty|macos|gui|nohup pins one rung (for testing).
want() { [ -z "${FORCE_BACKEND:-}" ] || [ "$FORCE_BACKEND" = "$1" ]; }

# 1. Already inside tmux (the ideal case): split the current window.
#    -d keeps focus on the agent's pane so your typing isn't hijacked.
if [ -z "$backend" ] && want tmux-split && [ -n "${TMUX:-}" ]; then
  if tmux split-window -d -h -l "${SPLIT_PERCENT}%" -c "$PWD" "$WRAPPER" 2>/dev/null \
  || tmux split-window -d -h -p "${SPLIT_PERCENT}"  -c "$PWD" "$WRAPPER" 2>/dev/null; then
    backend="tmux-split"
    attach="already visible in the pane beside you"
  fi
fi

# 2. WezTerm / kitty native splits.
if [ -z "$backend" ] && want wezterm && [ -n "${WEZTERM_PANE:-}" ] && try wezterm; then
  wezterm cli split-pane --right --percent "$SPLIT_PERCENT" -- "$WRAPPER" >/dev/null 2>&1 \
    && { backend="wezterm-split"; attach="already visible in the pane beside you"; }
fi
if [ -z "$backend" ] && want kitty && [ -n "${KITTY_WINDOW_ID:-}" ]; then
  (try kitten && kitten @ launch --type=window --cwd=current --title "$SESSION" "$WRAPPER" >/dev/null 2>&1) \
    && { backend="kitty-window"; attach="already visible in the split beside you"; }
fi

# 3. macOS: open a real Terminal/iTerm window.
if [ -z "$backend" ] && want macos && [ "$(uname -s)" = "Darwin" ] && try osascript; then
  if [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
    osascript -e 'tell application "iTerm"' \
              -e 'create window with default profile' \
              -e "tell current session of current window to write text \"$WRAPPER\"" \
              -e 'end tell' >/dev/null 2>&1 && backend="iterm-window"
  fi
  if [ -z "$backend" ]; then
    osascript -e "tell application \"Terminal\" to do script \"$WRAPPER\"" >/dev/null 2>&1 \
      && backend="macos-terminal"
  fi
  [ -n "$backend" ] && attach="a new terminal window opened"
fi

# 4. Linux with a display: first terminal emulator that exists wins.
if [ -z "$backend" ] && want gui && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  for t in gnome-terminal konsole xfce4-terminal alacritty wezterm foot xterm; do
    try "$t" || continue
    case "$t" in
      gnome-terminal) gnome-terminal --title="$SESSION" -- "$WRAPPER" ;;
      konsole)        konsole -p tabtitle="$SESSION" -e "$WRAPPER" ;;
      xfce4-terminal) xfce4-terminal --title="$SESSION" -x "$WRAPPER" ;;
      alacritty)      alacritty -t "$SESSION" -e "$WRAPPER" ;;
      wezterm)        wezterm start -- "$WRAPPER" ;;
      foot)           foot -T "$SESSION" "$WRAPPER" ;;
      xterm)          xterm -T "$SESSION" -e "$WRAPPER" ;;
    esac >/dev/null 2>&1 &
    backend="$t"; attach="a new terminal window opened"; break
  done
fi

# 5. Headless (SSH, container, CI): detached tmux — visible the moment you attach.
if [ -z "$backend" ] && try tmux; then
  tmux new-session -d -s "$SESSION" "$WRAPPER"
  backend="tmux-detached"
  attach="tmux attach -t $SESSION      # detach again with Ctrl-b then d"
fi

# 6. Absolute last resort.
if [ -z "$backend" ]; then
  nohup "$WRAPPER" </dev/null >/dev/null 2>&1 &
  backend="nohup"
  attach="tail -f $LOG"
fi

cat <<EOF
RUN_ID=$RUN_ID
RUN_DIR=$RUN_DIR
LOG=$LOG
STATUS=$RUN_DIR/status.json
SESSION=$SESSION
BACKEND=$backend
ATTACH=$attach
EOF
