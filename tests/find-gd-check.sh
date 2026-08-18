#!/bin/bash
# Geometry Dash lives in a different place for almost everyone. These are the
# layouts that have to resolve, including a Steam library on another volume.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GD_HOME="$TMP/home"; mkdir -p "$GD_HOME"
. "$ROOT/tools/find-gd.sh"

fails=0
chk() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1"; echo "         got:  $2"; echo "         want: $3"; fails=$((fails+1)); fi; }

mkgd() { mkdir -p "$1/Contents/MacOS" "$1/Contents/Frameworks"
         : > "$1/Contents/MacOS/Geometry Dash"; : > "$1/Contents/Frameworks/libfmod.dylib"; }
reset() { rm -rf "$TMP/home" "$TMP/vol"; mkdir -p "$TMP/home"; unset FPSUNCAP_GD_PATH; }

# 1. default Steam library
reset; P="$GD_HOME/Library/Application Support/Steam/steamapps/common/Geometry Dash/Geometry Dash.app"
mkgd "$P"; chk "default Steam library" "$(find_gd)" "$P"

# 2. a Steam library on another volume, declared in libraryfolders.vdf
reset; VDF="$GD_HOME/Library/Application Support/Steam/steamapps/libraryfolders.vdf"
mkdir -p "$(dirname "$VDF")"
cat > "$VDF" <<VDFEOF
"libraryfolders"
{
	"0"
	{
		"path"		"$GD_HOME/Library/Application Support/Steam"
	}
	"1"
	{
		"path"		"$TMP/vol/SteamLibrary"
	}
}
VDFEOF
P="$TMP/vol/SteamLibrary/steamapps/common/Geometry Dash/Geometry Dash.app"
mkgd "$P"; chk "Steam library on another volume" "$(find_gd)" "$P"

# 3. /Applications-style and loose copies
for loc in Applications Desktop Downloads Documents Games; do
    reset; P="$GD_HOME/$loc/Geometry Dash.app"; mkgd "$P"
    chk "~/$loc" "$(find_gd)" "$P"
done

# 4. a directory that is named right but is not an install must be rejected
reset; mkdir -p "$GD_HOME/Documents/Geometry Dash.app/Contents/MacOS"
chk "rejects a lookalike with no libfmod" "$(find_gd)" ""

# 5. explicit override always wins
reset; P="$GD_HOME/Documents/Geometry Dash.app"; mkgd "$P"
mkgd "$TMP/elsewhere/Geometry Dash.app"
export FPSUNCAP_GD_PATH="$TMP/elsewhere/Geometry Dash.app"
chk "--app override wins" "$(find_gd)" "$TMP/elsewhere/Geometry Dash.app"

exit $fails
