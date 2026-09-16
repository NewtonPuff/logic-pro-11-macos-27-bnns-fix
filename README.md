# Logic Pro 11.2.2 on macOS 27 — BNNS Compatibility Patch

Unofficial compatibility patch for a Logic Pro 11.2.2 / macOS 27 incompatibility in `MAMachineLearning.framework` and Apple's BNNS Graph API.

Logic Pro 11.2.2 expects an older BNNS Graph ABI. On the tested macOS 27 build, some legacy symbols are no longer exposed with the ABI Logic expects. The first visible failure was a pre-launch dyld error for `_BNNSGraphGetSize`.

This patch does not replace BNNS or disable the affected ML features. It creates a separate Logic Pro copy and adds a compatibility adapter that translates Logic's older BNNS calls to the current BNNS Graph / GraphContext interface.

## Tested configuration

- Logic Pro 11.2.2, build 6387
- macOS 27.0, build 26A428
- Apple Silicon / native ARM64
- SIP enabled

Runtime-tested successfully with ChromaGlow, Mastering Assistant, Stem Splitter, pitch-related features, Pedalboard/model-based effects, normal playback and ML model processing.

## What the patch does

- Verifies the exact supported Logic Pro build before patching.
- Copies `/Applications/Logic Pro.app`; the original is not modified.
- Neutralizes the obsolete direct `BNNSGraphGetSize` serializer path and marks the legacy import weak.
- Redirects Logic's private BNNS dynamic-loader path to a bundled compatibility adapter.
- Builds the adapter locally with Apple's command-line tools.
- Reconstructs current `bnns_graph_t` / compile-option objects for modern BNNS calls.
- Maps legacy graph inputs/outputs to current BNNS argument positions.
- Creates modern BNNS GraphContexts.
- Executes models using tensor-aware GraphContext arguments so shape/stride metadata is preserved.
- Ad-hoc signs only the modified copy and verifies the patched bytes afterward.

## What it does not do

It does not modify `/System`, replace Accelerate.framework, disable SIP, alter the Signed System Volume, change Logic licensing/trial state, or overwrite the original Logic Pro app.

## Install

1. Keep the original Logic Pro 11.2.2 at `/Applications/Logic Pro.app`.
2. Download and extract `Logic11-BNNS-Patcher.zip`.
3. Double-click `Logic11-BNNS-Patcher.command`.
4. The default output is `~/Desktop/Logic Pro 11 BNNS Patched.app`.
5. Launch the patched copy normally from Finder.

The patched app can stay on the Desktop or be moved to `/Applications` later. Do not overwrite your original Logic Pro app.

## Requirements

The patcher needs macOS command-line developer tools (`xcrun`, `clang`, `lipo`, `python3`) because `BNNSCompat.dylib` is built locally during installation.

## Safety checks

The patcher checks the original `MAMachineLearning` SHA-256 before changing anything:

```text
b7a4e954e202a605af48dc10f963de075def2ecdf4d1c239a7e5022eb3f125da
```

If the binary does not match the tested Logic 11.2.2 build, the patcher stops instead of applying offsets blindly.

## Scope and limitations

End-to-end ML runtime testing was performed on Apple Silicon. The compatibility source and patch logic include the x86_64 slice, but real Intel runtime behavior is not yet independently verified.

This patch is specific to the tested Logic Pro 11.2.2 build and the observed macOS 27 BNNS transition. Future Logic or macOS updates may change the ABI or make this patch unnecessary.

## Diagnostics

If a BNNS-related crash occurs, the adapter log is written to:

```text
/tmp/LogicBNNSCompat.log
```

Please include the macOS version/build, Logic version/build, Mac architecture, feature being used, the `.ips` crash report, and the adapter log when reporting an issue.

## Disclaimer

This project is unofficial and is not affiliated with or supported by Apple Inc. Keep backups of important projects and keep your original Logic Pro installation intact.
