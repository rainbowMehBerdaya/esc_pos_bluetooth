## [Unreleased]

- Fix Bluetooth state-listener leak in `writeBytes()`: every print job previously left a
  permanent listener attached, causing duplicate writes and double-completed futures on
  subsequent jobs.
- Fix idle-disconnect timer not being cancelled at the start of a job unless the selected
  printer changed, which could let a stale timer fire mid-connect/mid-write.
- Replace blocking `sleep()` between chunk writes with non-blocking `Future.delayed()` so
  printing no longer freezes the UI isolate; stop an in-flight transmission loop as soon as
  the print job's timeout fires instead of letting it keep writing in the background.
- Re-enable the "print already in progress" guard so overlapping `writeBytes()` calls are
  rejected instead of racing on the same connection.
- Fix a race where a new print job could start while a previous job's idle-disconnect was
  still in flight, causing it to skip reconnecting and hang until its own timeout.
- Bump pinned `flutter_bluetooth_basic` git ref to `0033fcdbdcf8021279bffec94f7dc229868309c3`:
  `writeData()` now genuinely reports write failures instead of always resolving success, and
  the Android connection-state stream is filtered to the printer's own device instead of
  reacting to any nearby Bluetooth peripheral. Reset the stale `_isConnected` flag when the
  platform reports a `not_connected` write failure.
  **Requires the corresponding `flutter_bluetooth_basic` commit to be pushed to
  `origin/updated` before `pub get` will resolve.**
- See `BLUETOOTH_WRITE_FIXES.md` for a detailed writeup.

## [0.4.1]

- Bump flutter_bluetooth_basic to ^0.1.7

## [0.4.0]

- Bump esc_pos_utils to ^1.1.0. Using Generator instead of Ticket

## [0.3.0]

- Null-Safety

## [0.2.8]

- Bump esc_pos_utils

## [0.2.7]

- Updated flutter_bluetooth_basic

## [0.2.6]

- Updated flutter_bluetooth_basic

## [0.2.5]

- Split data into chunks

## [0.2.4]

- `startScan` timeout bug fixed.
- Updated `esc_pos_utils` package version to `0.3.4`.

## [0.2.3]

- Updated `esc_pos_utils` package version to `0.3.3`.

## [0.2.2]

- Updated `esc_pos_utils` package version to `0.3.2`.

## [0.2.1]

- Updated `esc_pos_utils` package version to `0.3.1` (Open Cash Drawer).

## [0.2.0]

- Updated `esc_pos_utils` package version to `0.3.0` (Image and Barcode alignment).

## [0.1.1]

- Updated `esc_pos_utils`, `flutter_bluetooth_basic` package versions

## [0.1.0]

- Android and iOS Bluetooth printing support
