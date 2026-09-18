#!/bin/bash
set -euo pipefail

# Final Cut Pro 11.1 / macOS 27 BNNS compatibility patcher
# Ported from Logic11-BNNS-Patcher logic for FCP's nested MAMachineLearning 11.1 (922).
# Supports standard and trial installations of Final Cut Pro 11.1.
#
# Strategy (avoids fragile chained-import edits):
#  - Neutralize direct _BNNSGraphGetSize call + serializer branch (same as Logic).
#  - Redirect 2x dlopen strings to bundled adapter.
#  - Rename 2x import-pool strings "_BNNSGraphGetSize" -> "_vDSP_vadd" (exists in
#    Accelerate on macOS 27), so dyld strong bind succeeds. Direct call is NOP'd
#    so the rebound GOT slot is never used; dlsym path goes via adapter.
# Original app is NEVER modified; a Desktop copy is patched and ad-hoc signed.

if [ -d "${FCP_ORIG:-}" ]; then
    ORIG="$FCP_ORIG"
elif [ -d "/Applications/Final Cut Pro.app" ]; then
    ORIG="/Applications/Final Cut Pro.app"
elif [ -d "/Applications/Final Cut Pro Trial.app" ]; then
    ORIG="/Applications/Final Cut Pro Trial.app"
else
    ORIG="/Applications/Final Cut Pro.app"
fi
DEST="${FCP_PATCH_DEST:-$HOME/Desktop/Final Cut Pro 11 BNNS Patched.app}"
EXPECTED_VERSION="11.1"
EXPECTED_HASH="c0e0729bf54f2313eb168126a3631d2c804176cc5c41493c17182bbd7d7457c7"
FW_REL="Contents/Frameworks/EDEL.framework/Versions/A/Frameworks/MAMachineLearning.framework"
EDEL_REL="Contents/Frameworks/EDEL.framework"
BIN_REL="$FW_REL/Versions/A/MAMachineLearning"
SHIM_REL="$FW_REL/Versions/A/BNNSCompat.dylib"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM_SOURCE="$SCRIPT_DIR/FCPBNNSCompat.c"

OLD_DLOPEN_PATH="/System/Library/Frameworks/Accelerate.framework/Accelerate"
NEW_DLOPEN_PATH="@loader_path/BNNSCompat.dylib"
OLD_IMPORT_NAME="_BNNSGraphGetSize"
NEW_IMPORT_NAME="_vDSP_vadd"

say() { printf '%s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

TMP_WORK=""
cleanup_and_pause() {
    local code=$?
    if [ -n "${TMP_WORK:-}" ] && [ -d "$TMP_WORK" ]; then
        rm -rf "$TMP_WORK" || true
    fi
    if [ -t 0 ]; then
        printf '\nPress Return to close this window...'
        read -r _ || true
    fi
    exit "$code"
}
trap cleanup_and_pause EXIT

read_hex() {
    local file="$1" off="$2" len="$3"
    dd if="$file" bs=1 skip="$off" count="$len" 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

check_original_bytes() {
    local file="$1" off="$2" len="$3" expected="$4" label="$5"
    local got
    got="$(read_hex "$file" "$off" "$len")"
    [ "$got" = "$expected" ] || die "$label: unexpected original bytes at offset $(printf '0x%x' "$off"): got $got, expected $expected."
}

check_runtime_bnns27_symbols() {
    python3 <<'PY'
import ctypes, sys
lib = ctypes.CDLL("/System/Library/Frameworks/Accelerate.framework/Accelerate")
symbols = [
    "BNNSGraphCompileFromFile_v2","BNNSGraphContextMake","BNNSGraphContextExecute_v2",
    "BNNSGraphContextGetWorkspaceSize_v2","BNNSGraphContextGetTensor","BNNSTensorGetAllocationSize",
    "BNNSGraphContextSetArgumentType","BNNSGraphCompileOptionsMakeDefault",
    "BNNSGraphCompileOptionsSetTargetSingleThread","BNNSGraphCompileOptionsSetPredefinedOptimizations",
    "BNNSGraphGetInputCount","BNNSGraphGetInputNames_v2","BNNSGraphGetOutputCount",
    "BNNSGraphGetOutputNames_v2","BNNSGraphGetArgumentCount","BNNSGraphGetArgumentIntents",
    "BNNSGraphGetTensorDescriptor_v2","BNNSGraphGetArgumentPosition","BNNSGraphContextGetArgumentPosition",
    "vDSP_vadd",
]
missing=[]
for s in symbols:
    try:
        getattr(lib,s); print(f"FOUND: {s}")
    except AttributeError:
        print(f"MISSING: {s}"); missing.append(s)
if missing:
    print("Required macOS 27 symbols missing.", file=sys.stderr); raise SystemExit(1)
PY
}

say "============================================================"
say " Final Cut Pro 11.1 / macOS 27 - BNNS Patcher (port)"
say "============================================================"
say "Original app: $ORIG"
say "Patched copy: $DEST"
say ""

[ "$(uname -s)" = "Darwin" ] || die "macOS only."
[ -d "$ORIG" ] || die "Final Cut Pro application not found at: $ORIG"
[ -f "$SHIM_SOURCE" ] || die "FCPBNNSCompat.c must be next to this script."
[ ! -e "$DEST" ] || die "Destination exists: $DEST — move/delete it first."
command -v python3 >/dev/null || die "python3 required."
command -v xcrun >/dev/null || die "Xcode Command Line Tools required."
xcrun --find clang >/dev/null || die "clang not found."
command -v lipo >/dev/null || die "lipo not found."

OS_VERSION="$(sw_vers -productVersion)"
say "macOS: $OS_VERSION"

VERSION="$(defaults read "$ORIG/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
say "FCP version: ${VERSION:-unknown}"
[ "$VERSION" = "$EXPECTED_VERSION" ] || die "Expected Final Cut Pro $EXPECTED_VERSION, found '${VERSION:-unknown}'."

ORIG_BIN="$ORIG/$BIN_REL"
[ -f "$ORIG_BIN" ] || die "MAMachineLearning binary not found at $ORIG_BIN."
ACTUAL_HASH="$(shasum -a 256 "$ORIG_BIN" | awk '{print $1}')"
say "MAMachineLearning SHA-256: $ACTUAL_HASH"
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || die "Not the tested FCP 11.1 build. Expected: $EXPECTED_HASH"

# Exact original-byte checks (fat file offsets).
check_original_bytes "$ORIG_BIN" $((0xB60C)) 5 "e809630100" "x86_64 BNNSGraphGetSize call"
check_original_bytes "$ORIG_BIN" $((0xB62D)) 2 "740b"       "x86_64 serializer je"
check_original_bytes "$ORIG_BIN" $((0x3FDE8)) 4 "2c4f0094"  "arm64 BNNSGraphGetSize bl"
check_original_bytes "$ORIG_BIN" $((0x3FE08)) 4 "a8000034"  "arm64 serializer cbz"
check_original_bytes "$ORIG_BIN" $((0x2C70E)) 2 "0002"       "x86_64 n_desc flags"
check_original_bytes "$ORIG_BIN" $((0x6201E)) 2 "0002"       "arm64 n_desc flags"

python3 - "$ORIG_BIN" <<'PY'
import sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
old_dl = b"/System/Library/Frameworks/Accelerate.framework/Accelerate\0"
for off,arch in [(0x242C5,"x86_64"),(0x5731D,"arm64")]:
    assert data[off:off+len(old_dl)]==old_dl, f"{arch} dlopen mismatch"
assert data.count(old_dl)==2, f"expected 2 dlopen strings, found {data.count(old_dl)}"
old_imp = b"_BNNSGraphGetSize\0"
for off,arch in [(0x29319,"x86_64 import pool"),(0x60231,"arm64 import pool")]:
    assert data[off:off+len(old_imp)]==old_imp, f"{arch} import string mismatch"
assert data.count(old_imp)==4, f"expected 4 exact import+symtab strings, found {data.count(old_imp)}"
# symtab copies must exist (untouched references)
for off,arch in [(0x2E849,"x86_64 symtab"),(0x637E0,"arm64 symtab")]:
    assert data[off:off+len(old_imp)]==old_imp, f"{arch} symtab string mismatch"
print("OK: dlopen + import-pool + symtab strings verified")
PY

say "Preflight: checking macOS 27 BNNS runtime symbols..."
check_runtime_bnns27_symbols || die "macOS 27 BNNS ABI not available."

TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcp-bnns.XXXXXX")"
TMP_SHIM="$TMP_WORK/BNNSCompat.dylib"

say "1/6  Copying Final Cut Pro (original untouched)..."
ditto "$ORIG" "$DEST"

BIN="$DEST/$BIN_REL"
FW="$DEST/$FW_REL"
EDEL="$DEST/$EDEL_REL"
SHIM="$DEST/$SHIM_REL"
[ "$(shasum -a 256 "$BIN" | awk '{print $1}')" = "$EXPECTED_HASH" ] || { rm -rf "$DEST"; die "Copy hash mismatch. Removed."; }

say "2/6  Building universal BNNS compatibility adapter..."
xcrun --sdk macosx clang -std=c11 -O2 -Wall -Wextra -fvisibility=hidden \
  -arch arm64 -arch x86_64 -dynamiclib \
  -Wl,-install_name,@loader_path/BNNSCompat.dylib \
  -o "$TMP_SHIM" "$SHIM_SOURCE" || { rm -rf "$DEST"; die "Compile failed. Removed."; }
ARCHS="$(lipo -archs "$TMP_SHIM" 2>/dev/null || true)"
case " $ARCHS " in *" arm64 "*) ;; *) rm -rf "$DEST"; die "Adapter missing arm64.";; esac
case " $ARCHS " in *" x86_64 "*) ;; *) rm -rf "$DEST"; die "Adapter missing x86_64.";; esac
say "Adapter architectures: $ARCHS"
EXPORTS="$(nm -gU "$TMP_SHIM" 2>/dev/null || true)"
for sym in BNNSGraphCompileFromFile BNNSGraphExecute BNNSGraphOptionsCreateDefault \
  BNNSGraphOptionsSetSingleThread BNNSGraphGetWorkspaceSize BNNSGraphGetSize \
  BNNSGraphContextGetArgPosition BNNSGraphGetNumInputs BNNSGraphGetInputNames \
  BNNSGraphGetNumOutputs BNNSGraphGetOutputNames BNNSGraphGetTensorDescriptor \
  BNNSGraphOptionsSetPredefinedOptimizations BNNSGraphGetArgumentPosition; do
  printf '%s\n' "$EXPORTS" | grep -q "_${sym}$" || { rm -rf "$DEST"; die "Adapter export missing: $sym"; }
done
say "OK: adapter exports present"
cp "$TMP_SHIM" "$SHIM"; chmod 755 "$SHIM"

say "3/6  Applying binary patch..."
python3 - "$BIN" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
data = bytearray(p.read_bytes())
def patch(off, old_hex, new_hex, desc):
    old = bytes.fromhex(old_hex); new = bytes.fromhex(new_hex)
    assert len(old)==len(new), desc
    assert data[off:off+len(old)]==old, f"STOP {desc} at {off:#x}: got {data[off:off+len(old)].hex()}"
    data[off:off+len(old)]=new
    print(f"OK: {desc}")
patch(0xB60C,"e809630100","31c0909090","x86_64 call -> xor eax,eax+NOPs")
patch(0xB62D,"740b","9090","x86_64 je -> NOPs")
patch(0x3FDE8,"2c4f0094","000080d2","arm64 bl -> mov x0,#0")
patch(0x3FE08,"a8000034","1f2003d5","arm64 cbz -> NOP")
# n_desc weak flags: 00 02 -> 40 02 (both slices, belt-and-braces with import rename)
patch(0x2C70E,"0002","4002","x86_64 n_desc -> N_WEAK_REF")
patch(0x6201E,"0002","4002","arm64 n_desc -> N_WEAK_REF")
old_dl=b"/System/Library/Frameworks/Accelerate.framework/Accelerate\0"
new_dl=b"@loader_path/BNNSCompat.dylib\0"
rep_dl=new_dl+b"\0"*(len(old_dl)-len(new_dl))
for off,arch in [(0x242C5,"x86_64"),(0x5731D,"arm64")]:
    assert data[off:off+len(old_dl)]==old_dl, f"{arch} dlopen"
    data[off:off+len(old_dl)]=rep_dl
    print(f"OK: {arch} dlopen -> adapter")
old_imp=b"_BNNSGraphGetSize\0"
new_imp=b"_vDSP_vadd\0"+b"\0"*7
assert len(old_imp)==len(new_imp)
for off,arch in [(0x29319,"x86_64 import pool"),(0x60231,"arm64 import pool")]:
    assert data[off:off+len(old_imp)]==old_imp, f"{arch} import"
    data[off:off+len(old_imp)]=new_imp
    print(f"OK: {arch} import -> _vDSP_vadd")
p.write_bytes(data)
PY

say "4/6  Static-checking patched framework..."
python3 - "$BIN" <<'PY'
import sys
from pathlib import Path
data=Path(sys.argv[1]).read_bytes()
old_dl=b"/System/Library/Frameworks/Accelerate.framework/Accelerate\0"
new_dl=b"@loader_path/BNNSCompat.dylib\0"
assert old_dl not in data, "old dlopen remains"
assert data.count(new_dl)==2, f"dlopen count {data.count(new_dl)}"
assert data[0xB60C:0xB60C+5].hex()=="31c0909090"
assert data[0xB62D:0xB62D+2].hex()=="9090"
assert data[0x3FDE8:0x3FDE8+4].hex()=="000080d2"
assert data[0x3FE08:0x3FE08+4].hex()=="1f2003d5"
assert data[0x2C70E:0x2C70E+2].hex()=="4002"
assert data[0x6201E:0x6201E+2].hex()=="4002"
assert data[0x29319:0x29319+18]==b"_vDSP_vadd\0"+b"\0"*7
assert data[0x60231:0x60231+18]==b"_vDSP_vadd\0"+b"\0"*7
# symtab copies untouched
assert data[0x2E849:0x2E849+18]==b"_BNNSGraphGetSize\0"
assert data[0x637E0:0x637E0+18]==b"_BNNSGraphGetSize\0"
print("OK: all 10 patch sites verified, symtab intact")
PY
for ARCH in arm64 x86_64; do
  if otool -arch "$ARCH" -tvV "$BIN" 2>/dev/null | grep -q 'symbol stub for: _BNNSGraphGetSize'; then
    rm -rf "$DEST"; die "$ARCH still has direct _BNNSGraphGetSize stub call."
  fi
done

say "5/6  Ad-hoc signing (adapter, inner framework, EDEL)..."
codesign --force --sign - "$SHIM" || { rm -rf "$DEST"; die "codesign dylib failed."; }
codesign --verify --verbose=2 "$SHIM" || { rm -rf "$DEST"; die "dylib verify failed."; }
codesign --force --sign - "$FW" || { rm -rf "$DEST"; die "codesign inner FW failed."; }
codesign --verify --verbose=2 "$FW" || { rm -rf "$DEST"; die "inner FW verify failed."; }
codesign --force --sign - "$EDEL" || { rm -rf "$DEST"; die "codesign EDEL failed."; }
codesign --verify --verbose=2 "$EDEL" || { rm -rf "$DEST"; die "EDEL verify failed."; }

say "6/6  Done."
say ""
say "SUCCESS: $DEST"
say "Original untouched: $ORIG"
say "Launch the patched copy via right-click > Open. Test on a DUPLICATE library."
say "Adapter log: /tmp/FCPBNNSCompat.log"
