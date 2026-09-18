# Attribution

This FCP port is derived from the Logic Pro 11.2.2 / macOS 27 BNNS compatibility work:

- Upstream: `https://github.com/NewtonPuff/logic-pro-11-macos-27-bnns-fix`
- Upstream files at fork time: `Logic11-BNNS-Patcher.command`, `README.md`, `SHA256SUMS.txt`
  (plus the `BNNSCompat-v4.c` adapter source distributed in the author's release folder).
- `fcp/FCPBNNSCompat.c` here is that adapter source with one functional change: the log path
  ` /tmp/LogicBNNSCompat-v4.log` → `/tmp/FCPBNNSCompat.log`, so Logic and FCP runs don't interleave.
- `fcp/FCP-BNNS-Patcher.command` is a new script written for FCP's nested
  `EDEL.framework/.../MAMachineLearning 11.1 (922)` layout (different offsets, import-rename
  strategy documented in the README). Patch byte patterns for call/branch follow the upstream
  approach; FCP-specific offsets and the `_vDSP_vadd` import rename are original to this port.

License status (2026-09-18): upstream has no LICENSE file (all rights reserved by default).
This fork keeps upstream files untouched at repo root. The FCP port is offered back via PR;
if/when upstream adds a license (MIT suggested), this port will follow it. Until then, do not
republish the adapter source outside this fork/PR flow without the author's permission.
