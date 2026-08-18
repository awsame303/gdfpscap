#!/bin/bash
# Verifies the two things that must hold before touching anyone's game:
#   1. the pacer actually drives a display-link callback at the requested rate
#   2. the splicer's edits are exactly reversible
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { printf "  \033[32mPASS\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

clang -arch arm64 -O2 -Wno-deprecated-declarations \
  -framework CoreVideo -framework CoreFoundation \
  -o "$TMP/harness" "$ROOT/tests/harness.c" 2>/dev/null \
  || { echo "could not build harness"; exit 1; }

rate() { # env... -> callbacks per second
    env "$@" "$TMP/harness" 2 2>/dev/null | grep -oE '\(([0-9.]+)/s\)' | head -1 | tr -d '(/s)'
}
near() { # actual expected tolerance
    awk -v a="$1" -v e="$2" -v t="$3" 'BEGIN{exit !(a>e-t && a<e+t)}'
}

echo "pacing"
BASE=$(rate FPSUNCAP_X=0)
echo "    display refresh measured at ${BASE}/s"
for m in source runloop thread; do
    r=$(rate FPSUNCAP_MODE=$m FPSUNCAP_FPS=240 DYLD_INSERT_LIBRARIES="$BUILD/fpsuncap.dylib")
    near "$r" 240 12 && ok "mode=$m reaches 240/s (got $r)" || bad "mode=$m got $r, expected ~240"
done
r=$(rate FPSUNCAP_MODE=source FPSUNCAP_FPS=500 DYLD_INSERT_LIBRARIES="$BUILD/fpsuncap.dylib")
near "$r" 500 25 && ok "scales to 500/s (got $r)" || bad "500 target got $r"

r=$(rate FPSUNCAP_DISABLE=1 DYLD_INSERT_LIBRARIES="$BUILD/fpsuncap.dylib")
near "$r" "$BASE" 8 && ok "disable=1 falls back to display rate (got $r)" \
                    || bad "disable=1 got $r, expected ~$BASE"

echo "splicer"
# A fixture with realistic header padding (real app libraries have plenty;
# -headerpad is how the linker reserves it).
FIX="$TMP/fixture.dylib"
echo 'int fixture(void){return 0;}' > "$TMP/fix.c"
clang -arch arm64 -arch x86_64 -dynamiclib -Wl,-headerpad,0x1000 -o "$FIX" "$TMP/fix.c" 2>/dev/null
BEFORE=$(shasum "$FIX" | cut -d' ' -f1)
"$BUILD/machsplice" "$FIX" "@rpath/test-payload.dylib" >/dev/null
otool -l "$FIX" | grep -q "test-payload.dylib" && ok "adds LC_LOAD_DYLIB" || bad "load command missing"
n=$("$BUILD/machsplice" "$FIX" "@rpath/test-payload.dylib" | grep -oE '^spliced [0-9]+')
[ "$n" = "spliced 0" ] && ok "second run is a no-op" || bad "not idempotent ($n)"
"$BUILD/machsplice" --remove "$FIX" "@rpath/test-payload.dylib" >/dev/null
AFTER=$(shasum "$FIX" | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] && ok "removal restores byte-identical file" || bad "round-trip differs"

# Refusing to corrupt a file with no room is as important as succeeding.
SMALL="$TMP/small.dylib"
clang -arch arm64 -dynamiclib -o "$SMALL" "$TMP/fix.c" 2>/dev/null
SB=$(shasum "$SMALL" | cut -d' ' -f1)
"$BUILD/machsplice" "$SMALL" "@rpath/a-very-long-payload-name-to-exhaust-padding.dylib" >/dev/null 2>&1
SA=$(shasum "$SMALL" | cut -d' ' -f1)
[ "$SB" = "$SA" ] && ok "refuses to write when padding is insufficient" || bad "corrupted a file it should have refused"

echo "detection"
if out=$("$ROOT/tests/find-gd-check.sh" 2>&1); then
    ok "finds Geometry Dash in every supported layout"
else
    bad "Geometry Dash detection failed"; printf '%s\n' "$out" | sed 's/^/    /'
fi

echo "installer package"
if out=$("$ROOT/tests/pkg-check.sh" 2>&1); then
    ok "install / change fps / uninstall round-trips cleanly"
else
    bad "pkg postinstall round-trip failed"; printf '%s\n' "$out" | sed 's/^/    /'
fi

echo "dialogs"
if "$ROOT/tests/dialog-check.sh" >/dev/null 2>&1; then
    ok "every GUI dialog is valid AppleScript"
else
    bad "a GUI dialog does not compile (run tests/dialog-check.sh)"
fi

echo
printf "%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
