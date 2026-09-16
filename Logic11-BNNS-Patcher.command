#!/bin/bash
set -euo pipefail

# Logic Pro 11.2.2 / macOS 27 BNNS compatibility patcher
#
# Runtime ABI adapter for the BNNS Graph API transition observed
# on macOS 27. This keeps the weak-import/direct-call safety patches, then
# redirects MAMachineLearning's private BNNS dlsym loader to a bundled adapter
# dylib compiled locally from BNNSCompat.c.
#
# The original /Applications/Logic Pro.app is NEVER modified.

ORIG="/Applications/Logic Pro.app"
DEST="${LOGIC11_PATCH_DEST:-$HOME/Desktop/Logic Pro 11 BNNS Patched.app}"
EXPECTED_VERSION="11.2.2"
EXPECTED_HASH="b7a4e954e202a605af48dc10f963de075def2ecdf4d1c239a7e5022eb3f125da"
EXPECTED_PATCHED_PRE_SIGN_HASH="646cd2dc6f1c14621333e35ca51074e8d5005cfe7144c9608ceffe4038d7376a"
FW_REL="Contents/Frameworks/MAMachineLearning.framework"
BIN_REL="$FW_REL/Versions/A/MAMachineLearning"
SHIM_REL="$FW_REL/Versions/A/BNNSCompat.dylib"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM_SOURCE="$SCRIPT_DIR/BNNSCompat.c"

OLD_DLOPEN_PATH="/System/Library/Frameworks/Accelerate.framework/Accelerate"
NEW_DLOPEN_PATH="@loader_path/BNNSCompat.dylib"

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
    [ "$got" = "$expected" ] || die "$label: unexpected original bytes at offset $(printf '0x%x' "$off"): got $got, expected $expected. Source app was not modified."
}

check_patch_bytes() {
    local file="$1" off="$2" len="$3" expected="$4" label="$5"
    local got
    got="$(read_hex "$file" "$off" "$len")"
    [ "$got" = "$expected" ] || die "$label: verification failed at offset $(printf '0x%x' "$off"): got $got, expected $expected."
}

check_runtime_bnns27_symbols() {
    python3 <<'PY'
import ctypes
import sys

path = "/System/Library/Frameworks/Accelerate.framework/Accelerate"
try:
    lib = ctypes.CDLL(path)
except Exception as e:
    print(f"Could not load Accelerate: {e}", file=sys.stderr)
    raise SystemExit(1)

symbols = [
    "BNNSGraphCompileFromFile_v2",
    "BNNSGraphContextMake",
    "BNNSGraphContextExecute_v2",
    "BNNSGraphContextGetWorkspaceSize_v2",
    "BNNSGraphContextGetTensor",
    "BNNSTensorGetAllocationSize",
    "BNNSGraphContextSetArgumentType",
    "BNNSGraphCompileOptionsMakeDefault",
    "BNNSGraphCompileOptionsSetTargetSingleThread",
    "BNNSGraphCompileOptionsSetPredefinedOptimizations",
    "BNNSGraphGetInputCount",
    "BNNSGraphGetInputNames_v2",
    "BNNSGraphGetOutputCount",
    "BNNSGraphGetOutputNames_v2",
    "BNNSGraphGetArgumentCount",
    "BNNSGraphGetArgumentIntents",
    "BNNSGraphGetTensorDescriptor_v2",
    "BNNSGraphGetArgumentPosition",
    "BNNSGraphContextGetArgumentPosition",
]

missing = []
for s in symbols:
    try:
        getattr(lib, s)
        print(f"FOUND: {s}")
    except AttributeError:
        print(f"MISSING: {s}")
        missing.append(s)

if missing:
    print("Required macOS 27 BNNS runtime symbols are missing.", file=sys.stderr)
    raise SystemExit(1)
PY
}

verify_signed_fat_bytes() {
    python3 - "$1" <<'PY'
import struct
import sys
from pathlib import Path

p = Path(sys.argv[1])
data = p.read_bytes()

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_X86_64 = 0x01000007
CPU_ARM64 = 0x0100000C

if len(data) < 8:
    raise SystemExit("post-sign verifier: file is too small")

magic, nfat = struct.unpack_from(">II", data, 0)
if magic not in (FAT_MAGIC, FAT_MAGIC_64):
    raise SystemExit(f"post-sign verifier: unexpected fat Mach-O magic 0x{magic:08x}")

archs = {}
off = 8
if magic == FAT_MAGIC:
    entry_size = 20
    fmt = ">IIIII"
else:
    entry_size = 32
    fmt = ">IIQQII"

for _ in range(nfat):
    vals = struct.unpack_from(fmt, data, off)
    archs[vals[0]] = (vals[2], vals[3])
    off += entry_size

required = {CPU_X86_64: "x86_64", CPU_ARM64: "arm64"}
for cpu, name in required.items():
    if cpu not in archs:
        raise SystemExit(f"post-sign verifier: missing {name} slice")

old_path = b"/System/Library/Frameworks/Accelerate.framework/Accelerate\0"
new_path = b"@loader_path/BNNSCompat.dylib\0"
path_region = new_path + b"\0" * (len(old_path) - len(new_path))

checks = {
    CPU_X86_64: [
        (0x0c32c, bytes.fromhex("31c0909090"), "direct BNNSGraphGetSize call"),
        (0x0c34d, bytes.fromhex("9090"),       "serializer branch"),
        (0x2d098, bytes.fromhex("02fb0300"),   "weak chained import"),
        (0x30c5e, bytes.fromhex("4002"),       "N_WEAK_REF symbol flags"),
        (0x2740b, path_region,                  "BNNS adapter dlopen path"),
    ],
    CPU_ARM64: [
        (0x0c67c, bytes.fromhex("000080d2"),   "direct BNNSGraphGetSize call"),
        (0x0c69c, bytes.fromhex("1f2003d5"),   "serializer branch"),
        (0x30088, bytes.fromhex("02fb0300"),   "weak chained import"),
        (0x3257e, bytes.fromhex("4002"),       "N_WEAK_REF symbol flags"),
        (0x2649b, path_region,                  "BNNS adapter dlopen path"),
    ],
}

for cpu, name in required.items():
    base, size = archs[cpu]
    print(f"post-sign {name} slice: file offset 0x{base:x}, size 0x{size:x}")
    for rel, expected, label in checks[cpu]:
        if rel + len(expected) > size:
            raise SystemExit(f"post-sign verifier: {name} {label} offset 0x{rel:x} is outside slice")
        got = data[base + rel:base + rel + len(expected)]
        if got != expected:
            raise SystemExit(
                f"post-sign verifier: {name} {label} at slice+0x{rel:x}: "
                f"got {got.hex()}, expected {expected.hex()}"
            )
        print(f"OK: post-sign {name} {label}")

if old_path in data:
    raise SystemExit("post-sign verifier: old Accelerate dlopen path still exists in MAMachineLearning")
if data.count(new_path) != 2:
    raise SystemExit(f"post-sign verifier: expected 2 adapter dlopen strings, found {data.count(new_path)}")
PY
}

say "============================================================"
say " Logic Pro 11.2.2 / macOS 27 - BNNS Patcher"
say "============================================================"
say ""
say "Original app: $ORIG"
say "Patched copy: $DEST"
say ""

[ "$(uname -s)" = "Darwin" ] || die "This patcher is for macOS only."
[ -d "$ORIG" ] || die "Logic Pro.app was not found in /Applications."
[ -f "$SHIM_SOURCE" ] || die "BNNSCompat.c must be next to this .command file. Extract the complete ZIP first."
[ ! -e "$DEST" ] || die "The destination already exists: $DEST\nMove/delete it first, then run this patcher again."
command -v python3 >/dev/null 2>&1 || die "python3 is required."
command -v xcrun >/dev/null 2>&1 || die "Xcode Command Line Tools are required."
xcrun --find clang >/dev/null 2>&1 || die "clang was not found. Install Xcode Command Line Tools, then retry."
command -v lipo >/dev/null 2>&1 || die "lipo was not found."

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
say "macOS: $OS_VERSION"
if [ "$OS_MAJOR" != "27" ]; then
    say "WARNING: this compatibility adapter was developed for macOS 27."
    printf "Continue anyway? [y/N] "
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) die "Cancelled." ;;
    esac
fi

VERSION="$(defaults read "$ORIG/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
say "Logic version: ${VERSION:-unknown}"
[ "$VERSION" = "$EXPECTED_VERSION" ] || die "Expected Logic Pro $EXPECTED_VERSION, found '${VERSION:-unknown}'."

ORIG_BIN="$ORIG/$BIN_REL"
[ -f "$ORIG_BIN" ] || die "MAMachineLearning binary was not found."
ACTUAL_HASH="$(shasum -a 256 "$ORIG_BIN" | awk '{print $1}')"
say "MAMachineLearning SHA-256: $ACTUAL_HASH"
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || die "This is not the exact tested Logic 11.2.2 build. Expected SHA-256: $EXPECTED_HASH"

# Exact original-byte checks for the supported Logic build.
check_original_bytes "$ORIG_BIN" $((0x1032c)) 5 "e8dd7c0100" "x86_64 BNNSGraphGetSize call"
check_original_bytes "$ORIG_BIN" $((0x1034d)) 2 "740b"       "x86_64 serializer branch"
check_original_bytes "$ORIG_BIN" $((0x31098)) 4 "02fa0300" "x86_64 chained import"
check_original_bytes "$ORIG_BIN" $((0x34c5e)) 2 "0002"     "x86_64 symbol flags"
check_original_bytes "$ORIG_BIN" $((0x4c67c)) 4 "69560094" "arm64 BNNSGraphGetSize call"
check_original_bytes "$ORIG_BIN" $((0x4c69c)) 4 "a8000034" "arm64 serializer branch"
check_original_bytes "$ORIG_BIN" $((0x70088)) 4 "02fa0300" "arm64 chained import"
check_original_bytes "$ORIG_BIN" $((0x7257e)) 2 "0002"     "arm64 symbol flags"

# Exact original dynamic-loader strings in both slices.
python3 - "$ORIG_BIN" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
data = p.read_bytes()
old = b"/System/Library/Frameworks/Accelerate.framework/Accelerate\0"
for off, arch in [(0x2b40b, "x86_64"), (0x6649b, "arm64")]:
    got = data[off:off+len(old)]
    if got != old:
        raise SystemExit(f"{arch} BNNS dlopen string mismatch at 0x{off:x}")
if data.count(old) != 2:
    raise SystemExit(f"expected exactly two old BNNS dlopen strings, found {data.count(old)}")
print("OK: exact old BNNS dlopen strings found in both slices")
PY

say ""
say "Preflight: checking macOS 27 modern BNNS runtime symbols..."
check_runtime_bnns27_symbols || die "The expected macOS 27 BNNS ABI is not available on this system."

TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/logic-bnns.XXXXXX")"
TMP_SHIM="$TMP_WORK/BNNSCompat.dylib"

say ""
say "1/6  Copying Logic Pro (the original is left untouched)..."
ditto "$ORIG" "$DEST"

BIN="$DEST/$BIN_REL"
FW="$DEST/$FW_REL"
SHIM="$DEST/$SHIM_REL"
COPIED_HASH="$(shasum -a 256 "$BIN" | awk '{print $1}')"
[ "$COPIED_HASH" = "$EXPECTED_HASH" ] || { rm -rf "$DEST"; die "The copied binary does not match the source. The test copy was removed."; }

say "2/6  Building universal BNNS compatibility adapter..."
xcrun --sdk macosx clang \
    -std=c11 -O2 -Wall -Wextra \
    -fvisibility=hidden \
    -arch arm64 -arch x86_64 \
    -dynamiclib \
    -Wl,-install_name,@loader_path/BNNSCompat.dylib \
    -o "$TMP_SHIM" "$SHIM_SOURCE" \
    || { rm -rf "$DEST"; die "Could not compile BNNSCompat.dylib. The test copy was removed."; }

ARCHS="$(lipo -archs "$TMP_SHIM" 2>/dev/null || true)"
case " $ARCHS " in *" arm64 "*) ;; *) rm -rf "$DEST"; die "Adapter is missing arm64." ;; esac
case " $ARCHS " in *" x86_64 "*) ;; *) rm -rf "$DEST"; die "Adapter is missing x86_64." ;; esac
say "Adapter architectures: $ARCHS"

EXPORTS="$(nm -gU "$TMP_SHIM" 2>/dev/null || true)"
for sym in \
    BNNSGraphCompileFromFile BNNSGraphExecute BNNSGraphOptionsCreateDefault \
    BNNSGraphOptionsSetSingleThread BNNSGraphGetWorkspaceSize BNNSGraphGetSize \
    BNNSGraphContextGetArgPosition BNNSGraphGetNumInputs BNNSGraphGetInputNames \
    BNNSGraphGetNumOutputs BNNSGraphGetOutputNames BNNSGraphGetTensorDescriptor \
    BNNSGraphOptionsSetPredefinedOptimizations BNNSGraphGetArgumentPosition
do
    printf '%s\n' "$EXPORTS" | grep -q "_${sym}$" || { rm -rf "$DEST"; die "Adapter export missing: $sym"; }
done
say "OK: all Logic-facing compatibility exports are present"

cp "$TMP_SHIM" "$SHIM"
chmod 755 "$SHIM"

say "3/6  Applying binary patch..."
python3 - "$BIN" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
data = bytearray(p.read_bytes())

patches = [
    (0x1032c, bytes.fromhex("e8dd7c0100"), bytes.fromhex("31c0909090"),
     "x86_64 direct BNNSGraphGetSize call -> xor eax,eax + NOPs"),
    (0x1034d, bytes.fromhex("740b"), bytes.fromhex("9090"),
     "x86_64 serializer branch -> NOPs"),
    (0x31098, bytes.fromhex("02fa0300"), bytes.fromhex("02fb0300"),
     "x86_64 chained import -> weak"),
    (0x34c5e, bytes.fromhex("0002"), bytes.fromhex("4002"),
     "x86_64 symbol flags -> N_WEAK_REF"),
    (0x4c67c, bytes.fromhex("69560094"), bytes.fromhex("000080d2"),
     "arm64 direct BNNSGraphGetSize call -> mov x0,#0"),
    (0x4c69c, bytes.fromhex("a8000034"), bytes.fromhex("1f2003d5"),
     "arm64 serializer cbz -> NOP"),
    (0x70088, bytes.fromhex("02fa0300"), bytes.fromhex("02fb0300"),
     "arm64 chained import -> weak"),
    (0x7257e, bytes.fromhex("0002"), bytes.fromhex("4002"),
     "arm64 symbol flags -> N_WEAK_REF"),
]

for off, old, new, desc in patches:
    actual = data[off:off + len(old)]
    if actual != old:
        raise SystemExit(f"STOP: {desc}: bytes at {off:#x} are {actual.hex()}, expected {old.hex()}")
    data[off:off + len(old)] = new
    print(f"OK: {desc}")

old = b"/System/Library/Frameworks/Accelerate.framework/Accelerate\0"
new = b"@loader_path/BNNSCompat.dylib\0"
replacement = new + b"\0" * (len(old) - len(new))
for off, arch in [(0x2b40b, "x86_64"), (0x6649b, "arm64")]:
    actual = data[off:off+len(old)]
    if actual != old:
        raise SystemExit(f"STOP: {arch} BNNS dlopen path mismatch at {off:#x}")
    data[off:off+len(old)] = replacement
    print(f"OK: {arch} BNNS dlopen -> @loader_path/BNNSCompat.dylib")

p.write_bytes(data)
PY

# Verify exact pre-sign MAMachineLearning output.
PRE_SIGN_HASH="$(shasum -a 256 "$BIN" | awk '{print $1}')"
say "Patched pre-sign MAMachineLearning SHA-256: $PRE_SIGN_HASH"
[ "$PRE_SIGN_HASH" = "$EXPECTED_PATCHED_PRE_SIGN_HASH" ] || { rm -rf "$DEST"; die "The patched MAMachineLearning output hash does not match the expected build. The copied app was removed."; }

say "4/6  Static-checking patched framework..."
for ARCH in arm64 x86_64; do
    if otool -arch "$ARCH" -tvV "$BIN" 2>/dev/null | grep -q 'symbol stub for: _BNNSGraphGetSize'; then
        rm -rf "$DEST"
        die "$ARCH still contains a direct executable _BNNSGraphGetSize call."
    fi
done

python3 - "$BIN" <<'PY'
import sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
old = b"/System/Library/Frameworks/Accelerate.framework/Accelerate\0"
new = b"@loader_path/BNNSCompat.dylib\0"
if old in data:
    raise SystemExit("old Accelerate BNNS dlopen path still exists")
if data.count(new) != 2:
    raise SystemExit(f"expected two BNNSCompat loader paths, found {data.count(new)}")
print("OK: both BNNS dynamic-loader paths now target the adapter")
PY

say "5/6  Ad-hoc signing adapter and modified framework..."
codesign --force --sign - "$SHIM" || { rm -rf "$DEST"; die "codesign failed for BNNSCompat.dylib."; }
codesign --verify --verbose=2 "$SHIM" || { rm -rf "$DEST"; die "BNNSCompat.dylib signature verification failed."; }

codesign --force --sign - "$FW" || { rm -rf "$DEST"; die "codesign failed for MAMachineLearning.framework."; }
codesign --verify --verbose=2 "$FW" || { rm -rf "$DEST"; die "Framework signature verification failed."; }

verify_signed_fat_bytes "$BIN" || { rm -rf "$DEST"; die "Post-sign architecture-relative verification failed."; }

for ARCH in arm64 x86_64; do
    if otool -arch "$ARCH" -tvV "$BIN" 2>/dev/null | grep -q 'symbol stub for: _BNNSGraphGetSize'; then
        rm -rf "$DEST"
        die "$ARCH contains a direct executable _BNNSGraphGetSize call after signing."
    fi
done

say "6/6  Done."
say ""
say "SUCCESS - patched build created at:"
say "  $DEST"
say ""
say "Your original remains untouched at:"
say "  $ORIG"
say ""
say "What this patch changes:"
say "  - keeps the startup / weak-import / serializer safety patches"
say "  - redirects Logic's old BNNS dlsym loader to BNNSCompat.dylib"
say "  - maps Logic's legacy output/input pointer vector to modern BNNS positions by name"
say "  - executes through BNNSGraphContext in BNNSTensor mode, preserving shape/stride metadata"
say "  - uses guarded shadow buffers only for NULL or provably undersized legacy allocations"
say ""
say "IMPORTANT: this is an unofficial compatibility build; keep the original app untouched."
say "Tested targets include ChromaGlow, Mastering Assistant, Stem Splitter, pitch-related features and model-based effects."
say ""
say "Adapter log (after launch):"
say "  /tmp/LogicBNNSCompat.log"
say ""
say "You can now double-click the generated app in Finder."
say ""
