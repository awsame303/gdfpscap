#!/bin/bash
# The package postinstall is the real install path, so it has to round-trip:
# install -> change fps -> uninstall must leave libfmod.dylib byte-identical.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" /tmp/fpsuncap-install' EXIT
GD="$TMP/Geometry Dash.app"; FW="$GD/Contents/Frameworks"
mkdir -p "$FW" "$GD/Contents/MacOS"

echo 'int f(void){return 0;}' > "$TMP/s.c"; echo 'int main(void){return 0;}' > "$TMP/m.c"
clang -arch arm64 -dynamiclib -Wl,-headerpad,0x4000 -install_name @rpath/libfmod.dylib \
      -o "$FW/libfmod.dylib" "$TMP/s.c" 2>/dev/null
clang -arch arm64 -dynamiclib -o "$FW/Geode.dylib" "$TMP/s.c" 2>/dev/null
codesign --remove-signature "$FW/Geode.dylib" 2>/dev/null       # Geode ships unsigned
clang -arch arm64 -o "$GD/Contents/MacOS/Geometry Dash" "$TMP/m.c" "$FW/libfmod.dylib" \
      -Wl,-rpath,@executable_path/../Frameworks 2>/dev/null
codesign -f -s - "$GD" 2>/dev/null
BEFORE=$(shasum "$FW/libfmod.dylib" | cut -d' ' -f1)

# Canned dialog answers, so nothing appears on screen.
cat > "$TMP/gui" <<'GUI'
#!/bin/bash
case "$1" in
  *"choose from list"*) echo "${ANSWER_MENU:-Reinstall / repair}";;
  *"default answer"*)   echo "button returned:Set, text returned:${ANSWER_FPS:-360}";;
  *)                    echo "button returned:OK";;
esac
GUI
chmod +x "$TMP/gui"

stage() { rm -rf /tmp/fpsuncap-install; mkdir -p /tmp/fpsuncap-install
          cp "$ROOT/build/fpsuncap.dylib" "$ROOT/build/machsplice" \
             "$ROOT/tools/fpsuncap" "$ROOT/tools/find-gd.sh" /tmp/fpsuncap-install/; }
run() { stage; env FPSUNCAP_GD_PATH="$GD" FPSUNCAP_TEST_GUI="$TMP/gui" \
        FPSUNCAP_USER_HOME="$TMP/home" "$@" bash "$ROOT/pkg/postinstall" >/dev/null 2>&1; }

fails=0
chk() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; fails=$((fails+1)); fi; }

mkdir -p "$TMP/home"
# 1. install, choosing 360 fps
run ANSWER_FPS=360
otool -l "$FW/libfmod.dylib" 2>/dev/null | grep -q fpsuncap && r=yes || r=no
chk "install splices the payload" "$r" "yes"
codesign -v "$GD" >/dev/null 2>&1 && r=valid || r=invalid
chk "bundle signature valid after install" "$r" "valid"

# 2. change fps only
run ANSWER_MENU="Change FPS" ANSWER_FPS=144
chk "change fps writes the config" \
    "$(grep -E '^fps=' "$TMP/home/Library/Application Support/FPSUncap/config" | cut -d= -f2)" "144"
otool -l "$FW/libfmod.dylib" 2>/dev/null | grep -q fpsuncap && r=yes || r=no
chk "change fps leaves the splice alone" "$r" "yes"

# 3. uninstall
run ANSWER_MENU="Uninstall completely"
otool -l "$FW/libfmod.dylib" 2>/dev/null | grep -q fpsuncap && r=yes || r=no
chk "uninstall removes the load command" "$r" "no"
chk "uninstall restores libfmod byte-for-byte" "$(shasum "$FW/libfmod.dylib" | cut -d' ' -f1)" "$BEFORE"
[ -f "$FW/fpsuncap.dylib" ] && r=present || r=gone
chk "uninstall removes the payload" "$r" "gone"

exit $fails
