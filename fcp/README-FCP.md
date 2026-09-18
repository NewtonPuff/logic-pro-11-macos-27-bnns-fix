# Final Cut Pro Trial 11.1 on macOS 27 — BNNS Compatibility Patch (FCP port)

Unofficial compatibility patch for Final Cut Pro Trial 11.1 dying at launch on macOS 27 with:

```text
Termination Reason: Namespace DYLD, Code 4, Symbol missing
Symbol not found: _BNNSGraphGetSize
Referenced from: .../EDEL.framework/.../MAMachineLearning.framework/.../MAMachineLearning
Expected in: .../Accelerate.framework
```

Same macOS 27 BNNS Graph ABI transition that breaks Logic Pro 11.x. This port applies the same
copy-only adapter strategy to FCP's nested `MAMachineLearning 11.1 (922)`.

Upstream Logic fix this is ported from (attribution — see `ATTRIBUTION.md`):
`https://github.com/NewtonPuff/logic-pro-11-macos-27-bnns-fix`

## Tested configuration

- Final Cut Pro Trial 11.1 (440108), inner `MAMachineLearning 11.1 (922)`
  - SHA-256: `c0e0729bf54f2313eb168126a3631d2c804176cc5c41493c17182bbd7d7457c7`
- macOS 27.0 (26A428), Apple Silicon ARM64, SIP enabled
- Launch-tested: patched copy stays alive past dyld (stock dies in <1s). ML runtime testing is
  ongoing — please report Enhance Audio / masking results with the adapter log (below).

## What it does

- Verifies the exact FCP 11.1 build by version + SHA-256 before touching anything.
- Copies `/Applications/Final Cut Pro Trial.app` (5.9G) — the original is never modified.
- Neutralizes the obsolete direct `BNNSGraphGetSize` call + serializer branch (both slices).
- Sets `N_WEAK_REF` on the legacy import (belt-and-braces).
- Redirects both internal BNNS `dlopen` strings to a bundled compatibility adapter.
- Renames both import-pool strings `_BNNSGraphGetSize` → `_vDSP_vadd` (verified present in
  macOS 27 Accelerate), so the strong dyld bind succeeds. The rebound GOT slot is never
  called (direct call is NOP'd); the real `dlsym("BNNSGraphGetSize")` path resolves via adapter.
- Builds the adapter locally (`FCPBNNSCompat.c`, universal arm64+x86_64) with Apple clang.
- Ad-hoc signs only the copy (adapter → inner framework → EDEL.framework) and verifies bytes.

## What it does not do

No `/System` change, no Accelerate replacement, no SIP disable, no SSV change, no license/trial
change, no overwrite of the original app.

## Install (new users)

1. Keep stock `Final Cut Pro Trial 11.1` at `/Applications/Final Cut Pro Trial.app`.
2. Back up your libraries (e.g. `~/Movies/*.fcpbundle` + `Final Cut Backups.localized`) to external.
   The tester backup was only ~120M — do it anyway and test on a DUPLICATE library.
3. Free disk: the duplicate is 5.9G, have 30G+ free (`df -h /System/Volumes/Data`).
4. In this `fcp/` folder, double-click `FCP-BNNS-Patcher.command`
   (or `chmod +x FCP-BNNS-Patcher.command && ./FCP-BNNS-Patcher.command`).
5. Output by default: `~/Desktop/Final Cut Pro Trial BNNS Patched.app`.
6. Launch the patched copy via right-click → Open (first time, to clear Gatekeeper).
7. Open a duplicate library first. Try ML features, then check `/tmp/FCPBNNSCompat.log`
   for `succeeded` vs `ERROR rc=-1` + shadow-buffer counts.

Do NOT overwrite your original app. Do NOT move the patched copy over it.

## Requirements

macOS command-line tools: `xcrun`, `clang`, `lipo`, `python3`. The adapter is compiled locally —
no prebuilt binary blob.

## Safety checks

- Version must read `11.1`, binary hash must equal the tested build above, or the script stops.
- All 10 patch sites (call, branch ×2 slices, n_desc ×2, dlopen ×2, import rename ×2) are checked
  byte-exact before AND after. Symtab copies of the old name are verified intact (proves the
  rename hit the import pool, not debug strings).
- `otool` confirms no direct `_BNNSGraphGetSize` stub call remains per arch.

## Diagnostics

Adapter log:

```text
/tmp/FCPBNNSCompat.log
```

If an ML feature fails, include: macOS version/build, FCP version/build, Mac arch, feature used,
newest `~/Library/Logs/DiagnosticReports/Final Cut Pro*.ips`, and the adapter log.

## Status / disclaimer

Experimental port, launch-verified, ML runtime validation ongoing. Same caveats as upstream:
unofficial, not affiliated with Apple, keep originals + backups. For deadlines prefer the
official current Final Cut via App Store / Creator Studio trial.
