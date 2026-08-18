#!/bin/bash
# Every dialog gui.sh can produce must be valid AppleScript. A stray quote in a
# message compiles to nothing, the dialog never appears, and the app looks like
# it silently did nothing -- indistinguishable from a real failure. This drives
# gui.sh with osascript replaced by a syntax checker, walking every menu branch
# and feeding it CLI output that contains quotes.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/res"

cat > "$TMP/bin/osascript" <<'SHIM'
#!/bin/bash
src=""; while [ $# -gt 0 ]; do [ "$1" = "-e" ] && { src="$2"; shift 2; continue; }; shift; done
if ! err=$(osacompile -o /dev/null -e "$src" 2>&1); then
    printf '%s\n--- offending script ---\n%s\n\n' "$err" "$src" >> "$CHECK_DIR/failures"
    exit 1
fi
if printf '%s' "$src" | grep -q 'choose from list'; then
    # Answer once, then quit, so the menu loop cannot spin forever.
    if [ -f "$CHECK_DIR/answered" ]; then echo ""; else
        : > "$CHECK_DIR/answered"; echo "${CHECK_CHOICE:-}"
    fi
    exit 0
fi
btn=$(printf '%s' "$src" | sed -n 's/.*default button "\([^"]*\)".*/\1/p')
[ -n "$btn" ] && echo "button returned:$btn, text returned:240" || echo ""
SHIM
chmod +x "$TMP/bin/osascript"
cp "$ROOT/tools/gui.sh" "$TMP/res/gui.sh"
export CHECK_DIR="$TMP"; : > "$TMP/failures"

make_cli() { # installed_state  cmd_rc
    cat > "$TMP/res/fpsuncap" <<CLI
#!/bin/bash
case "\$1" in
  status) echo "installed      : $1"
          # deliberately quoted, to prove dialog text is escaped
          echo 'Geometry Dash : /Users/x/My "Games"/Geometry Dash.app'
          echo "loop fps      : 240"; echo "present fps   : 0"
          echo "mode          : source"; echo "enabled       : yes";;
  install|uninstall)
          [ "$2" -eq 0 ] && exit 0
          echo 'cp: /x/libfmod.dylib: Operation not permitted'
          echo 'error: splice failed'; exit 1;;
  *)      exit 0;;
esac
CLI
    chmod +x "$TMP/res/fpsuncap"
}

run() {
    rm -f "$TMP/answered"
    PATH="$TMP/bin:$PATH" bash "$TMP/res/gui.sh" >/dev/null 2>&1 &
    local p=$!; local n=0
    while kill -0 $p 2>/dev/null && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done
    kill -9 $p 2>/dev/null; wait $p 2>/dev/null
}

# First-run paths: install denied (EPERM) and install accepted.
for rc in 1 0; do make_cli no "$rc"; export CHECK_CHOICE=""; run; done

# Main-menu paths: walk every option, with the CLI both succeeding and failing.
for rc in 0 1; do
    make_cli yes "$rc"
    for c in "Change FPS (currently 240)" "Reinstall / repair" "Turn off temporarily" \
             "Uninstall completely" "Show status" "Launch Geometry Dash" ""; do
        export CHECK_CHOICE="$c"; run
    done
done

if [ -s "$TMP/failures" ]; then
    echo "INVALID APPLESCRIPT:"; cat "$TMP/failures"; exit 1
fi
exit 0
