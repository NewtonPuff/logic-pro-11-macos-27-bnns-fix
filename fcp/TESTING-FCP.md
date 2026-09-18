# Testing the FCP port

Start `Final Cut Pro 11 BNNS Patched.app` via right-click → Open.

1. Open a DUPLICATE library (never your live `~/Movies/*.fcpbundle` first).
2. Play back a normal timeline — confirms base app + signing fine.
3. Try ML-backed features one at a time (e.g. Enhance Audio, Scene Removal Mask). Note the
   exact feature + timestamp for each try.
4. Check the adapter log:

```bash
tail -n 50 /tmp/FCPBNNSCompat.log
```

Look for `first Tensor BNNSGraphContextExecute_v2 call succeeded` (good) vs
`ERROR: first BNNSGraphContextExecute_v2 failure rc=-1` + shadow-buffer lines.

If anything crashes, collect:

```bash
LATEST="$(ls -t ~/Library/Logs/DiagnosticReports/"Final Cut Pro"* 2>/dev/null | head -1)"
cp "$LATEST" "$HOME/Desktop/FCP-BNNS-crash.ips"
cp /tmp/FCPBNNSCompat.log "$HOME/Desktop/FCP-BNNS-adapter.log" 2>/dev/null || true
```

Attach both + macOS/FCP versions + Mac arch + feature + timestamp to the issue/PR.
