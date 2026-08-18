#!/bin/bash
# Native dialog front end. Everything here delegates to the fpsuncap CLI, so
# the two can never drift apart.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/fpsuncap"
[ -x "$CLI" ] || CLI="$HERE/../build/fpsuncap"
TITLE="FPS Uncap for Geometry Dash"

# Attributing dialogs to System Events is what reliably brings them to the
# front from a bundle with no real UI of its own.
# Never write inside the bundle -- that breaks its signature seal.
OSA_ERR=""
OSA_TMP="${TMPDIR:-/tmp}/fpsuncap-osa.$$"
trap 'rm -f "$OSA_TMP"' EXIT
osa() {
    local out rc
    out=$(osascript -e "tell application \"System Events\" to $1" 2>"$OSA_TMP")
    rc=$?
    OSA_ERR="$(cat "$OSA_TMP" 2>/dev/null)"
    printf '%s' "$out"
    return $rc
}

# Strip the CLI's ANSI colouring; escape codes render as garbage in a dialog.
plain() { printf '%s' "$1" | sed $'s/\033\[[0-9;]*m//g'; }

# Escape for embedding in an AppleScript string literal. Only double quotes --
# backslashes must survive, because the messages rely on \n for line breaks.
esc() { printf '%s' "$1" | sed 's/"/\\"/g'; }

say() { # message [icon]
    osa "display dialog \"$(esc "$1")\" with title \"$TITLE\" buttons {\"OK\"} default button \"OK\" with icon ${2:-note}" >/dev/null
}

ask_yes_no() { # message yes_label no_label
    local r
    r=$(osa "display dialog \"$(esc "$1")\" with title \"$TITLE\" buttons {\"$3\", \"$2\"} default button \"$2\" with icon note")
    [[ "$r" == *"button returned:$2"* ]]
}

is_installed() { "$CLI" status 2>/dev/null | grep -q "installed      : yes"; }
current_fps()  { "$CLI" status 2>/dev/null | grep "loop fps" | sed 's/.*: //' | tr -d ' '; }

# ------------------------------------------------------------------ steps ---

ask_fps() {
    local cur fps r
    cur="$(current_fps)"; cur="${cur:-240}"
    while true; do
        r=$(osa "display dialog \"How many frames per second should the game loop run at?\n\nCommon choices:\n   240  — recommended, matches most practice setups\n   360  — for very fast machines\n   120  — lighter on the CPU\n\nYour display still shows its own refresh rate; this raises how often the game updates.\" default answer \"$cur\" with title \"$TITLE\" buttons {\"Cancel\", \"Set\"} default button \"Set\" with icon note")
        [[ "$r" == *"button returned:Set"* ]] || return 1
        fps=$(echo "$r" | sed 's/.*text returned://')
        if [[ "$fps" =~ ^[0-9]+$ ]] && [ "$fps" -ge 30 ] && [ "$fps" -le 2000 ]; then
            local out; out="$("$CLI" set "$fps" 2>&1)"
            if [ $? -eq 0 ]; then
                say "Game loop set to $fps FPS.\n\nIf Geometry Dash is open, quit and reopen it." note
                return 0
            fi
            say "Could not save the setting:\n\n$(plain "$out")" stop
            return 1
        fi
        say "Please enter a whole number between 30 and 2000." caution
    done
}

do_install() {
    local out
    out="$("$CLI" install 2>&1)"
    if [ $? -ne 0 ]; then
        case "$out" in
            *running*)    say "Please quit Geometry Dash first, then try again." caution;;
            *"could not find"*) say "Could not find Geometry Dash.\n\nIf it is installed somewhere unusual, move it to your Applications folder and try again." stop;;
            *"not permitted"*)
                # macOS TCC. Writing libfmod.dylib means modifying a file
                # sealed into Geometry Dash's signature, which needs App
                # Management permission. An ad-hoc signed app is not offered
                # the consent prompt, so it has to be granted by hand.
                if ask_yes_no "macOS is blocking FPS Uncap from modifying Geometry Dash.\n\nOpen System Settings > Privacy & Security > App Management and turn on FPS Uncap, then try again.\n\nIf FPS Uncap is not listed there, drag it in with the + button, or run this in Terminal:\n\n$CLI install" "Open Settings" "Later"; then
                    open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles" 2>/dev/null \
                      || open "x-apple.systempreferences:com.apple.preference.security?Privacy" 2>/dev/null
                fi;;
            *permission*|*"cannot write"*) say "No permission to modify Geometry Dash.\n\nIf it lives in /Applications, make sure your account is an administrator." stop;;
            *)            say "Install failed:\n\n$(plain "$out")" stop;;
        esac
        return 1
    fi
    return 0
}

launch_gd() { open -a "Geometry Dash" 2>/dev/null; }

# ------------------------------------------------------------- first run ---

first_run() {
    ask_yes_no "This will let Geometry Dash run its game loop faster than your display's refresh rate.\n\nIt changes a file inside Geometry Dash. The original is backed up and can be restored at any time with Uninstall.\n\nInstall now?" "Install" "Not now" || exit 0
    do_install || exit 1
    ask_fps || true
    if ask_yes_no "Done. Geometry Dash is ready.\n\nLaunch it now?" "Launch" "Later"; then launch_gd; fi
}

# ------------------------------------------------------------- main menu ---

main_menu() {
    local choice fps
    while true; do
        fps="$(current_fps)"; fps="${fps:-240}"
        choice=$(osascript -e "tell application \"System Events\" to choose from list {\"Change FPS (currently $fps)\", \"Reinstall / repair\", \"Turn off temporarily\", \"Uninstall completely\", \"Show status\", \"Launch Geometry Dash\"} with title \"$TITLE\" with prompt \"FPS Uncap is installed.\" OK button name \"Choose\" cancel button name \"Quit\"" 2>/dev/null)
        case "$choice" in
            false|"") exit 0;;
            "Change FPS"*)     ask_fps || true;;
            "Reinstall"*)      do_install && say "Reinstalled successfully." note;;
            "Turn off"*)       "$CLI" off >/dev/null 2>&1 && say "Turned off. Geometry Dash will behave normally.\n\nIt stays installed — turn it back on from this menu." note;;
            "Uninstall"*)
                if ask_yes_no "Restore Geometry Dash to its original state?" "Uninstall" "Cancel"; then
                    out="$("$CLI" uninstall 2>&1)"
                    if [ $? -eq 0 ]; then say "Uninstalled. Geometry Dash is back to stock." note; exit 0
                    else case "$out" in
                        *running*) say "Please quit Geometry Dash first." caution;;
                        *) say "Uninstall failed:\n\n$(plain "$out")" stop;;
                    esac; fi
                fi;;
            "Show status")     say "$(plain "$("$CLI" status 2>&1)")" note;;
            "Launch"*)         launch_gd; exit 0;;
        esac
    done
}

# Turned-off installs still reach the menu so they can be turned back on.
if "$CLI" status 2>/dev/null | grep -q "enabled       : no"; then
    if ask_yes_no "FPS Uncap is installed but currently turned off.\n\nTurn it back on?" "Turn on" "Open menu"; then
        "$CLI" on >/dev/null 2>&1
        say "Turned on. Restart Geometry Dash to apply." note
    fi
    main_menu
elif is_installed; then
    main_menu
else
    first_run
fi
