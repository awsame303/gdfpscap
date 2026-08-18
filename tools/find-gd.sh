# Shared Geometry Dash detection. Sourced by the CLI and inlined into the
# package postinstall, so the two can never disagree about where GD lives.
#
# Expects: $GD_HOME (the user's home) and optionally $GD_RUNAS (a command
# prefix used to run mdfind as the console user from a root postinstall).

gd_looks_real() {
    [ -d "$1" ] \
      && [ -f "$1/Contents/MacOS/Geometry Dash" ] \
      && [ -f "$1/Contents/Frameworks/libfmod.dylib" ]
}

# Every Steam library root, not just the default one: users routinely put a
# library on an external drive, and libraryfolders.vdf is the only record of it.
gd_steam_roots() {
    local steam="$GD_HOME/Library/Application Support/Steam"
    echo "$steam"
    local vdf
    for vdf in "$steam/steamapps/libraryfolders.vdf" "$steam/config/libraryfolders.vdf"; do
        [ -f "$vdf" ] || continue
        # entries look like:  "path"  "/Volumes/Games/SteamLibrary"
        sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p' "$vdf"
        # older format numbers them:  "1"  "/Volumes/Games/SteamLibrary"
        sed -n 's/^[[:space:]]*"[0-9]\{1,\}"[[:space:]]*"\([^"]*\)".*/\1/p' "$vdf"
    done
}

gd_candidates() {
    local r
    gd_steam_roots | while read -r r; do
        [ -n "$r" ] && echo "$r/steamapps/common/Geometry Dash/Geometry Dash.app"
    done
    echo "/Applications/Geometry Dash.app"
    echo "$GD_HOME/Applications/Geometry Dash.app"
    echo "$GD_HOME/Desktop/Geometry Dash.app"
    echo "$GD_HOME/Downloads/Geometry Dash.app"
    echo "$GD_HOME/Documents/Geometry Dash.app"
    echo "$GD_HOME/Games/Geometry Dash.app"
}

find_gd() {
    [ -n "${FPSUNCAP_GD_PATH:-}" ] && { echo "$FPSUNCAP_GD_PATH"; return; }
    local c
    while read -r c; do
        gd_looks_real "$c" && { echo "$c"; return; }
    done <<< "$(gd_candidates)"

    # Last resort: ask Spotlight. Skip backups and anything that is not a real
    # install, and never trust the first hit blindly.
    while read -r c; do
        [ -n "$c" ] || continue
        case "$c" in *backup*|*Backup*|*.Trash*) continue;; esac
        gd_looks_real "$c" && { echo "$c"; return; }
    done <<< "$(${GD_RUNAS:-} mdfind -name "Geometry Dash.app" 2>/dev/null | grep -E "Geometry Dash\.app$")"
}
