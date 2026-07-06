# `PrinterBluetoothManager.writeBytes()` — concurrency and lifecycle fixes

This document explains the bugs that existed in `writeBytes()` / `_bluetoothDisconnectSuccess()`
in `lib/src/printer_bluetooth_manager.dart`, the patch that fixed the listener-leak class of
bugs, the new problems that patch introduced as a side effect, and the follow-up fixes applied
on top of it. It's meant to be read by anyone touching this file next, so the reasoning doesn't
have to be re-derived from scratch.

## Background

`writeBytes()` is the core of every print job: connect (if needed) → listen for the platform's
Bluetooth connection state → once `CONNECTED`, send the ticket bytes in small chunks → resolve
a `PosPrintResult`. It has accumulated several rounds of ad-hoc fixes over time (see the original
`// TODO`/commented-out code), and state is shared across calls via a handful of instance
booleans (`_isConnected`, `_isPrinting`) and `Timer`s — there is no formal state machine, so bugs
here tend to be timing/interleaving bugs rather than plain logic bugs.

## Round 1 — the listener-leak patch

The original code called `_bluetoothManager.state.listen(...)` fresh on every `writeBytes()`
call and never cancelled it. After N print jobs, N listeners were permanently attached to the
same broadcast stream. A single future Bluetooth event would then fire all of them at once,
causing:

- duplicate chunk transmission for old, already-finished jobs
- `Bad state: Future already completed` when an old job's completer was completed twice
- competing idle-disconnect timers stomping on each other, since `_timeoutTimer` was a single
  shared instance field reused by both the 12s print-timeout **and** the unrelated 5s
  disconnect-check in `_bluetoothDisconnectSuccess()`

The fix (already applied to this file):

- each `writeBytes()` call now keeps its own local `stateSubscription` and `timeoutTimer`, and a
  `finish(result)` closure that cancels both and completes the completer exactly once
  (guarded by `completer.isCompleted`)
- the idle-disconnect timer (`_disconnectBluetoothTimer`) is now cancelled at the **start** of
  every job, not only when the selected printer changes — a stale timer could otherwise fire
  mid-connect or mid-write
- `dart:io`'s blocking `sleep()` between chunk writes was replaced with
  `await Future.delayed(...)`, so the chunk-transmission loop no longer freezes the whole
  isolate (and with it, the platform-channel event delivery this class depends on) for the
  entire duration of a print job
- `_bluetoothDisconnectSuccess()` got its own local timer/subscription instead of sharing (and
  clobbering) the print job's timeout timer

This fixed the leak, but the last two changes above — non-blocking delays and per-job local
state — opened three new timing windows, described below. All three are now fixed in this repo's
copy of the file.

## Round 2 — three new problems this patch introduced, and their fixes

### 1. The 12s timeout didn't stop the transmission it timed out

**The bug:** `writeChunked()` sends chunks in a loop with `await Future.delayed(...)` between
each one. Because that delay is non-blocking, Dart's event loop is free to run other code while
a chunk transfer is in progress — including the 12-second `timeoutTimer`. Previously, the
blocking `sleep()` made this structurally impossible (the isolate was frozen, so the timer could
never fire mid-loop). Once `finish(PosPrintResult.timeout)` runs, it cancels the subscription and
completes the completer — but nothing told the still-running `writeChunked()` loop to stop. It
kept calling `_bluetoothManager.writeData()` for the remaining chunks in the background. Worse,
once that abandoned loop eventually finished, the code unconditionally went on to call
`_armDisconnectTimer()` (or `finish(PosPrintResult.success)`) for a job the caller had already
been told had failed — potentially clobbering a disconnect timer a *new*, legitimate job had
already armed, or writing over that new job's bytes on the same connection.

This is not just a theoretical race: with the default `chunkSizeBytes: 20` and
`queueSleepTimeMs: 20`, roughly 600 chunks (~12KB) already consume the entire 12-second budget
from the inter-chunk delay alone, before counting real Bluetooth write latency — any ticket with
a logo, QR code, or raster image can trigger this.

**The fix:** a local `isFinished` flag, flipped to `true` inside `finish()`:

```dart
bool isFinished = false;

void finish(PosPrintResult result) {
  _isPrinting = false;
  isFinished = true;
  timeoutTimer?.cancel();
  stateSubscription?.cancel();
  if (!completer.isCompleted) {
    completer.complete(result);
  }
}

Future<void> writeChunked() async {
  final len = bytes.length;
  for (var i = 0; i < len; i += chunkSizeBytes) {
    if (isFinished) {
      return; // stop as soon as the job has already been resolved
    }
    final end = (i + chunkSizeBytes < len) ? i + chunkSizeBytes : len;
    await _bluetoothManager.writeData(bytes.sublist(i, end));
    await Future.delayed(Duration(milliseconds: queueSleepTimeMs));
  }
}
```

and a matching guard right after `writeChunked()` returns, in both the Android and iOS
`CONNECTED` handlers, so the "job succeeded" tail (arming the disconnect timer, completing
`success`) never runs for a job that was already timed out:

```dart
try {
  await writeChunked();
} catch (_) {
  finish(PosPrintResult.timeout);
  break;
}

if (isFinished) {
  // The 12s timeout already fired while writeChunked() was still running;
  // the caller has already been told this job failed.
  break;
}

if (_capabilityProfile?.name != 'DEVICE') {
  _armDisconnectTimer();
} else {
  _isConnected = false;
}

finish(PosPrintResult.success);
```

Since Dart is single-threaded/cooperative, there's no race in reading `isFinished` — it's set
synchronously by whichever callback runs first (the timer or the write loop), and any other
code only observes it after its own next `await` resumes.

### 2. No protection against two overlapping `writeBytes()` calls

**The bug:** the reentrancy guard (`if (_isPrinting) return printInProgress;`) had been
commented out at some point in the file's history, and `_isPrinting` was otherwise unused. This
gap existed before this patch too, but it used to be harmless *by accident*: the old blocking
`sleep()` froze the isolate during every chunk write, so even if two `writeBytes()` calls somehow
both reached the write stage, one loop would run to completion before the isolate could ever
schedule the other's continuation — true interleaving was impossible. Once chunk delays became
non-blocking, two overlapping jobs (e.g. a UI double-tap, or a caller retrying right as a slow
job is finishing) can now really run concurrently: each has its own `hasWritten` flag and its own
`stateSubscription` on the same shared broadcast stream, both can observe the same `CONNECTED`
event, and both can call `_bluetoothManager.writeData()` at the same time — interleaving bytes
on the wire and corrupting the printed ticket(s).

**The fix:** re-enable the guard, now that `_isPrinting` is reliably reset to `false` on every
exit path via `finish()` (success, caught write error, or timeout):

```dart
} else if (_isPrinting) {
  // Reject overlapping jobs instead of letting two writeChunked() loops
  // race on the same connection: with the blocking sleep() removed below,
  // two concurrent loops can genuinely interleave writes on the wire.
  return Future<PosPrintResult>.value(PosPrintResult.printInProgress);
}
```

placed alongside the existing `printerNotSelected` / `scanInProgress` early-return checks, before
`_isPrinting` is set to `true`.

### 3. A new job could start against a connection that was already being torn down

**The bug:** the idle-disconnect timer (`_armDisconnectTimer`) fires 10 seconds after a
successful print and, if still connected, calls `await _bluetoothManager.disconnect()` before
setting `_isConnected = false`. In Dart, a one-shot `Timer`'s `isActive` becomes `false` the
instant the timer **fires** — not once its (possibly `async`) callback body finishes running.
So there was a window between "the timer fired and started disconnecting" and "`_isConnected`
was actually set to `false`" during which:

1. a new `writeBytes()` call's `if (_disconnectBluetoothTimer.isActive) cancel();` guard was a
   no-op (the timer had already fired, so `isActive` was already `false`)
2. `_isConnected` still read as `true` (the in-flight `disconnect()` hadn't resolved yet), so the
   new job's `if (!_isConnected) { ...connect... }` block was skipped entirely
3. shortly after, the old timer's callback finished and set `_isConnected = false`, tearing down
   the very connection the new job assumed was live
4. the new job — having never called `connect()` — would never receive a `CONNECTED` event, and
   would sit idle until its own 12-second timeout fired

This requires a real (if usually brief) `disconnect()` platform round-trip to overlap with a new
print starting roughly 10 seconds after the previous one — realistic for besides a manual print,
any queue/kiosk/batch-printing setup with a natural pace of prints a few seconds apart.

**The fix:** track the in-flight disconnect as an awaitable `Future`, not just via `Timer.isActive`:

```dart
// Tracks an idle-disconnect that has already fired and is mid-flight, so a
// new job can await the real outcome instead of trusting stale state.
Future<void>? _pendingDisconnect;
```

```dart
void _armDisconnectTimer() {
  if (_disconnectBluetoothTimer.isActive) {
    _disconnectBluetoothTimer.cancel();
  }

  _disconnectBluetoothTimer = Timer(Duration(seconds: 10), () {
    _pendingDisconnect = _disconnectIfConnected();
  });
}

Future<void> _disconnectIfConnected() async {
  if (_isConnected) {
    await _bluetoothManager.disconnect();
    _isConnected = false;
  }
  _pendingDisconnect = null;
}
```

and, at the top of `writeBytes()`, right after the existing `isActive`-based cancel (which still
handles the common case of a timer that hasn't fired yet):

```dart
// Timer.isActive flips to false the instant the timer FIRES, not once its
// async callback finishes — so a fired-but-still-running disconnect could
// otherwise race a new job. Wait for it to actually finish.
if (_pendingDisconnect != null) {
  await _pendingDisconnect;
}
```

This closes the window completely: if the idle timer has already fired and is mid-disconnect,
the new job now waits for that disconnect to actually finish (and `_isConnected` to be correctly
updated) before deciding whether it needs to reconnect.

## What's different from the patch you sent

The patch you sent (`fix: prevent listener leaks, disconnect-timer race, and UI-blocking sleeps
in writeBytes`, authored by Vincent, co-authored by Claude Fable 5) was applied to this repo
**unchanged** — every hunk in it is present exactly as sent. On top of it, this repo adds three
additional changes the original patch didn't include, closing races that patch itself introduced.
Nothing from the original patch was reverted or altered; the additions are net-new code layered
on top of it.

| # | In the patch you sent | Added on top, in this repo |
|---|---|---|
| 1 | `writeChunked()` had no way to stop early; the 12s `timeoutTimer` could fire mid-loop and the loop kept writing chunks in the background regardless. | New `isFinished` flag, set inside `finish()`. `writeChunked()` checks it every iteration and returns early; the `CONNECTED` handlers check it right after `writeChunked()` returns and skip arming the disconnect timer / completing `success` if the job was already timed out. |
| 2 | The `printInProgress` reentrancy guard stayed commented out — nothing in the patch re-enabled it, so two overlapping `writeBytes()` calls could both reach the write stage. | Uncommented/re-enabled the `else if (_isPrinting) return printInProgress;` check, now safe because `finish()` reliably resets `_isPrinting` on every exit path. |
| 3 | `_armDisconnectTimer()`'s callback did `if (_isConnected) { await disconnect(); _isConnected = false; }` with only `Timer.isActive` guarding re-entry from a new job — a no-op once the timer had already fired. | New `Future<void>? _pendingDisconnect` field, set when the timer fires and cleared once the disconnect actually completes. `writeBytes()` now `await`s it before deciding whether to reconnect, in addition to the original `isActive` check. |
| — | `_bluetoothDisconnectSuccess()` rewritten to use its own local timer/subscription (unchanged from your patch). | Not touched further — no new issue found here. |
| — | `writeData()` failures caught and reported as `PosPrintResult.timeout` (unchanged from your patch). | Still `timeout` (no dedicated enum value added) — but see "Round 3" below: the dependency bump means this `catch` now genuinely fires on real write failures, and `not_connected` failures also reset `_isConnected`. |
| — | Android/iOS `CONNECTED` handlers duplicate the `hasWritten`/try-catch/success block (unchanged from your patch). | **Not fixed** — flagged as cleanup, not a correctness bug, left for a future pass. |

In short: everything you sent is in the diff as-is; three extra guards (`isFinished`,
`printInProgress` re-enabled, `_pendingDisconnect`) were added because they close races that
only became *possible* as a side effect of your patch's own fixes (non-blocking delays, per-job
local state) — see "Round 2" above for the full reasoning behind each one.

## Round 3 — `flutter_bluetooth_basic` dependency bump (commit `0033fcd`)

The pinned dependency itself was updated to fix the root cause the "known limitation" below used
to describe. `pubspec.yaml`'s `flutter_bluetooth_basic` git ref moved from
`22bc68053d0b9a98eb806b5dc0cbad9d75bc8c38` to `0033fcdbdcf8021279bffec94f7dc229868309c3`.

What changed at the API boundary:

- **`writeData()` now actually reports failure.** Previously it fired the platform call and
  resolved `true` instantly, regardless of outcome (`bluetooth_manager.dart` used to do
  `_channel.invokeMethod(...); return Future.value(true);` without awaiting). It now `await`s the
  platform call and either resolves `true` (the write genuinely reached the port) or throws a
  `PlatformException` with one of three codes: `not_connected` (new — the port wasn't open when
  the write was attempted), `write_failed` (existing code, but now fires for real I/O failures
  instead of only an unreachable byte-conversion bug), or `bytes_empty` (unchanged).
- **The Android connection-state stream is now filtered to the printer's own MAC address.**
  Previously any nearby Bluetooth peripheral's connect/disconnect (headset, watch, ...) could
  flip `_isConnected` in this file, since the native side forwarded every ACL broadcast
  regardless of which device it was for. This is a pure bug fix on the dependency's side — no
  code changes were needed here to benefit from it, since `writeBytes()` already only reacts to
  `BluetoothManager.CONNECTED`/`DISCONNECTED` however they arrive.
- **Two native-side crash fixes** (a `disconnect()` NPE when it raced with an in-flight
  `connect()`, and an `EventSink` used-after-cancel guard) — invisible at this file's API surface,
  no action needed.

What was changed here in response, on top of Round 2's fixes:

- The `catch` blocks around `writeChunked()` in both the Android and iOS `CONNECTED` handlers now
  inspect the exception: if it's a `PlatformException` with code `not_connected`, `_isConnected`
  is explicitly reset to `false` before calling `finish(PosPrintResult.timeout)`. Previously
  (Round 2), a bare `catch (_)` would report the failure but leave `_isConnected` however it was
  — if the platform says the port wasn't actually open, that stale `true` could make the *next*
  job also skip reconnecting and repeat the same failure. Now the flag is corrected as soon as we
  learn it was wrong.
- `PosPrintResult` for all other failures is still `timeout` (the enum has no dedicated
  "write failed" value yet — see below); only the internal `_isConnected` bookkeeping changed.

**Verification**: `flutter pub get && dart analyze` pass with the new ref resolved locally via a
temporary `path:` override (the commit exists in the local `flutter_bluetooth_basic` checkout on
branch `updated`, but as of this writing **has not been pushed to `origin/updated` on GitHub** —
`flutter pub get` against the `git:`/`ref:` dependency will fail with `bad object <ref>` until
that push happens). `pubspec.yaml` here is left pointing at the git ref (the correct end state),
not the local path, but **the push is a prerequisite for `pub get` to succeed for anyone else** —
including CI, and anyone else pulling this branch.

## Known limitations that were *not* changed (documented, not fixed)

These were identified during review but left alone, since fixing them would mean either a public
API change or a larger structural rewrite beyond the scope of this bug-fix:

- **Write failures are still reported as `PosPrintResult.timeout`, not a dedicated value.** As of
  Round 3, the dependency genuinely surfaces write failures (see above), and this file's `catch`
  genuinely catches them now — the mislabeling is real, not moot. `not_connected` failures at
  least self-correct `_isConnected` internally, but the caller-visible result for every write
  failure (`not_connected`, `write_failed`, or anything else) is still the same generic
  `PosPrintResult.timeout` ("Error. Printer connection timeout"), because there is no dedicated
  `PosPrintResult` value for "write failed" in `lib/src/enums.dart`. Adding one (e.g.
  `PosPrintResult.writeFailed`) — and optionally branching on `e.code` to distinguish
  "never connected" from "disconnected mid-write" — would be a reasonable, additive follow-up.
- **Some duplication remains** between the Android and iOS `CONNECTED` handlers (the
  `hasWritten` guard + try/`writeChunked`/catch + success-completion block is copy-pasted), and
  between the two `finish()` closures in `writeBytes()` and `_bluetoothDisconnectSuccess()`
  (cancel-timer/cancel-subscription/guard-`isCompleted`/complete). Both are candidates for
  extraction into shared helpers if this file is touched again.
- **The underlying design is still "shared broadcast stream + scattered instance booleans + ad
  hoc Timers"**, not a real state machine. The fixes above close the specific races that were
  found, but the next change to this file should be reviewed with the same care — this pattern
  is prone to producing new timing bugs, not because any one fix is wrong, but because state is
  split between long-lived instance fields and short-lived per-call closures with no single
  place that owns the connection lifecycle.

## Verification performed

- `flutter pub get && dart analyze lib/src/printer_bluetooth_manager.dart` → no issues.
- No automated tests exist for this class (`test/` only has a placeholder test), and it depends
  on real Bluetooth hardware/platform channels, so the races described above were verified by
  manual code tracing (confirmed independently by multiple review passes) rather than by an
  automated repro — worth keeping in mind if a real device is available to smoke-test a print
  job that exceeds ~12s of transmission time.
