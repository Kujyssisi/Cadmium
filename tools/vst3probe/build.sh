#!/usr/bin/env bash
# Builds the probe plugin as a VST3 bundle. Windows by default, since that is
# the build it exists to test; pass "linux" for the other one.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="$HERE/../../native/vendor/vst3"
TARGET="${1:-windows}"
OUT="${2:-$HERE/out}"

if [[ "$TARGET" == "windows" ]]; then
  CXX=x86_64-w64-mingw32-g++
  SUB="x86_64-win"
  EXT=".vst3"
  LIBS="-lgdi32 -luser32 -static-libgcc -static-libstdc++ -static -lpthread"
else
  CXX=g++
  SUB="x86_64-linux"
  EXT=".so"
  LIBS=""
fi

BUNDLE="$OUT/CdProbe.vst3/Contents/$SUB"
mkdir -p "$BUNDLE"
"$CXX" -shared -O2 -std=c++17 -fPIC -I"$SDK" \
  -o "$BUNDLE/CdProbe$EXT" "$HERE/probe.cpp" $LIBS
echo "built $BUNDLE/CdProbe$EXT"

# The same plugin again, shaped the way FabFilter's are: one object that also
# names itself as its own controller class. A host that makes a second copy of
# it ends up drawing one instance and hearing another.
TWIN="$OUT/CdProbeTwin.vst3/Contents/$SUB"
mkdir -p "$TWIN"
"$CXX" -shared -O2 -std=c++17 -fPIC -DCD_PROBE_CTRL_CID -I"$SDK" \
  -o "$TWIN/CdProbeTwin$EXT" "$HERE/probe.cpp" $LIBS
echo "built $TWIN/CdProbeTwin$EXT"

# And one more: an instrument that only stops a note when the note-off names
# the same note id the note-on did. A host that gets that wrong leaves it
# playing forever, which is the whole point of having it.
NOTES="$OUT/CdProbeNotes.vst3/Contents/$SUB"
mkdir -p "$NOTES"
"$CXX" -shared -O2 -std=c++17 -fPIC -DCD_PROBE_NOTES -I"$SDK" \
  -o "$NOTES/CdProbeNotes$EXT" "$HERE/probe.cpp" $LIBS
echo "built $NOTES/CdProbeNotes$EXT"
