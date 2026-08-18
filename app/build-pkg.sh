#!/bin/bash
# Assemble FPS Uncap.pkg. The payload is staged in /tmp and moved into
# Geometry Dash by a root postinstall -- the same shape Geode uses, and the
# reason it works where a double-clicked .app is blocked by App Management.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build}"
VERSION="${2:-1.0.0}"
STAGE="$OUT/pkgroot"

[ -f "$ROOT/build/fpsuncap.dylib" ] || { echo "run 'make' first"; exit 1; }

rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "$ROOT/build/fpsuncap.dylib" "$ROOT/build/machsplice" \
   "$ROOT/tools/fpsuncap" "$ROOT/tools/find-gd.sh" "$STAGE/"
chmod +x "$STAGE/machsplice" "$STAGE/fpsuncap"
xattr -cr "$STAGE" 2>/dev/null || true

pkgbuild \
  --root "$STAGE" \
  --scripts "$ROOT/pkg" \
  --identifier io.github.awsame303.fpsuncap \
  --version "$VERSION" \
  --install-location /tmp/fpsuncap-install \
  "$OUT/FPS Uncap.pkg" >/dev/null

rm -rf "$STAGE"
echo "built $OUT/FPS Uncap.pkg"
