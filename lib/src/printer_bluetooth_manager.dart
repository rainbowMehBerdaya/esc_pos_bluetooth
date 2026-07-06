/*
 * esc_pos_bluetooth
 * Created by Andrey Ushakov
 *
 * Copyright (c) 2019-2020. All rights reserved.
 * See LICENSE for distribution and usage details.
 */

import 'dart:async';
import 'dart:io';

import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_bluetooth_basic/flutter_bluetooth_basic.dart';
import 'package:rxdart/rxdart.dart';

import './enums.dart';

/// Bluetooth printer
class PrinterBluetooth {
  PrinterBluetooth(this._device);

  final BluetoothDevice _device;

  String? get name => _device.name;

  String? get address => _device.address;

  int? get type => _device.type;

  Map<String, dynamic> get toJson => _device.toJson();
}

/// Printer Bluetooth Manager
class PrinterBluetoothManager {
  final BluetoothManager _bluetoothManager = BluetoothManager.instance;
  Timer _disconnectBluetoothTimer = Timer(Duration.zero, () {});
  // Tracks an idle-disconnect that has already fired and is mid-flight, so a
  // new job can await the real outcome instead of trusting stale state.
  Future<void>? _pendingDisconnect;
  bool _isPrinting = false;
  bool _isConnected = false;
  bool _supportBLE = true;
  StreamSubscription? _scanResultsSubscription;
  StreamSubscription? _isScanningSubscription;
  PrinterBluetooth? _selectedPrinter;
  CapabilityProfile? _capabilityProfile;
  bool _changeConnection = false;

  bool get supportBLE => _supportBLE;
  final BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);

  Stream<bool> get isScanningStream => _isScanning.stream;
  final BehaviorSubject<List<PrinterBluetooth>> _scanResults = BehaviorSubject.seeded([]);

  Stream<List<PrinterBluetooth>> get scanResults => _scanResults.stream;
  final BehaviorSubject<List<PrinterBluetooth>> _scanResultsNonScan = BehaviorSubject.seeded([]);

  Stream<List<PrinterBluetooth>> get scanResultsNonScan => _scanResultsNonScan.stream;

  void startScan(Duration timeout) async {
    _scanResults.add(<PrinterBluetooth>[]);

    _bluetoothManager.startScan(timeout: timeout);

    _scanResultsSubscription = _bluetoothManager.scanResults.listen((devices) {
      _scanResults.add(devices.map((d) => PrinterBluetooth(d)).toList());
    });

    _isScanningSubscription = _bluetoothManager.isScanning.listen((isScanningCurrent) async {
      // If isScanning value changed (scan just stopped)
      if (_isScanning.value && !isScanningCurrent) {
        _scanResultsSubscription!.cancel();
        _isScanningSubscription!.cancel();
      }
      _isScanning.add(isScanningCurrent);
    });
  }

  Future<bool> enablePermission() async {
    try {
      return await _bluetoothManager.enablePermission();
    } catch (e) {
      throw e;
    }
  }

  Future<bool> enableBluetooth() async {
    try {
      return await _bluetoothManager.enableBluetooth();
    } catch (e) {
      throw e;
    }
  }

  Future<bool> checkSupportBLE() async {
    try {
      _supportBLE = await _bluetoothManager.checkSupportBLE();
      return _supportBLE;
    } catch (e) {
      throw e;
    }
  }

  Future<List<PrinterBluetooth>> getBondedDevice() async {
    try {
      List<BluetoothDevice> listBluetoothDevices = await _bluetoothManager.getBondedDevice();
      _scanResultsNonScan.add(listBluetoothDevices.map((d) => PrinterBluetooth(d)).toList());
      return _scanResultsNonScan.value;
    } catch (e) {
      throw e;
    }
  }

  void stopScan() async {
    await _bluetoothManager.stopScan();
  }

  void selectPrinter(PrinterBluetooth printer, CapabilityProfile? capabilityProfile) {
    if (printer != _selectedPrinter) {
      _changeConnection = true;
    }

    if (capabilityProfile != null) {
      _capabilityProfile = capabilityProfile;
    }

    _selectedPrinter = printer;
  }

  Future<PosPrintResult> writeBytes(
    List<int> bytes, {
    int chunkSizeBytes = 20,
    int queueSleepTimeMs = 20,
  }) async {
    final Completer<PosPrintResult> completer = Completer();

    const int timeout = 12;
    if (_selectedPrinter == null) {
      return Future<PosPrintResult>.value(PosPrintResult.printerNotSelected);
    } else if (_isScanning.value) {
      return Future<PosPrintResult>.value(PosPrintResult.scanInProgress);
    } else if (_isPrinting) {
      // Reject overlapping jobs instead of letting two writeChunked() loops
      // race on the same connection: with the blocking sleep() removed below,
      // two concurrent loops can genuinely interleave writes on the wire.
      return Future<PosPrintResult>.value(PosPrintResult.printInProgress);
    }

    _isPrinting = true;

    // Always disarm the idle-disconnect timer before starting a job.
    // A timer armed by the previous job would otherwise fire mid-connect or
    // mid-write and drop the connection.
    if (_disconnectBluetoothTimer.isActive) {
      _disconnectBluetoothTimer.cancel();
    }

    // Timer.isActive flips to false the instant the timer FIRES, not once its
    // async callback finishes — so a fired-but-still-running disconnect could
    // otherwise race a new job: _isConnected would look stale-true here, this
    // job would skip reconnecting, and then the in-flight disconnect would
    // pull the connection out from under it. Wait for it to actually finish.
    if (_pendingDisconnect != null) {
      await _pendingDisconnect;
    }

    if (_changeConnection) {
      _changeConnection = false;

      if (_isConnected) {
        await _bluetoothManager.disconnect();

        if (Platform.isAndroid) {
          await _bluetoothDisconnectSuccess();
        }

        _isConnected = false;
      }
    }

    if (!_isConnected) {
      if (supportBLE) {
        // We have to rescan before connecting, otherwise we can connect only once
        await _bluetoothManager.startScan(timeout: Duration(seconds: 1));
        await _bluetoothManager.stopScan();
      }

      // Connect
      if (_capabilityProfile != null && _capabilityProfile!.name == 'IMIN-USB') {
        await _bluetoothManager.connectUSB();
      } else {
        await _bluetoothManager.connect(_selectedPrinter!._device);
      }
    }

    StreamSubscription<int?>? stateSubscription;
    Timer? timeoutTimer;
    // The state stream can emit CONNECTED more than once per job; this guard
    // makes sure the ticket is transmitted at most once.
    bool hasWritten = false;
    // Future.delayed (unlike the old blocking sleep()) lets the timeout timer
    // fire while writeChunked() is still mid-loop. This flag lets the loop
    // notice and stop, and lets the CONNECTED handler skip its post-write
    // steps (arming the disconnect timer, completing success) for a job that
    // has already been reported to the caller as timed out.
    bool isFinished = false;

    void finish(PosPrintResult result) {
      _isPrinting = false;
      isFinished = true;
      timeoutTimer?.cancel();
      // Cancel the subscription so listeners do not accumulate across jobs.
      // Leaked listeners caused duplicate writes and double completions.
      stateSubscription?.cancel();
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    Future<void> writeChunked() async {
      final len = bytes.length;
      for (var i = 0; i < len; i += chunkSizeBytes) {
        if (isFinished) {
          return;
        }
        final end = (i + chunkSizeBytes < len) ? i + chunkSizeBytes : len;
        await _bluetoothManager.writeData(bytes.sublist(i, end));
        // Yield to the event loop between chunks; dart:io sleep() blocked the
        // whole isolate, freezing the UI and the platform channel events this
        // class depends on.
        await Future.delayed(Duration(milliseconds: queueSleepTimeMs));
      }
    }

    if (Platform.isAndroid) {
      stateSubscription = _bluetoothManager.state.listen((state) async {
        switch (state) {
          case 12:
            if (_isConnected) {
              continue continueThis;
            }

            if (_capabilityProfile != null && _capabilityProfile!.name == 'IMIN-USB') {
              continue continueThis;
            }

            if (_capabilityProfile != null && _capabilityProfile!.name == 'DEVICE') {
              continue continueThis;
            }

            break;
          continueThis:
          case BluetoothManager.CONNECTED:
            _isConnected = true;

            if (hasWritten) {
              break;
            }
            hasWritten = true;

            try {
              await writeChunked();
            } catch (e) {
              // "not_connected" means the platform's port was already closed
              // even though we believed we were connected; clear the stale
              // flag so the next job reconnects instead of repeating this
              // same failure. Report failure instead of leaking an
              // unhandled async error.
              if (e is PlatformException && e.code == 'not_connected') {
                _isConnected = false;
              }
              finish(PosPrintResult.timeout);
              break;
            }

            if (isFinished) {
              // The 12s timeout already fired while writeChunked() was still
              // running; the caller has been told this job failed, so don't
              // arm a fresh disconnect timer or complete the (already
              // completed) completer with success.
              break;
            }

            if (_capabilityProfile?.name != 'DEVICE') {
              _armDisconnectTimer();
            } else {
              _isConnected = false;
            }

            finish(PosPrintResult.success);
            break;
          case BluetoothManager.DISCONNECTED:
            _isConnected = false;
            break;
          default:
            break;
        }
      });
    } else if (Platform.isIOS) {
      stateSubscription = _bluetoothManager.state.listen((state) async {
        switch (state) {
          case null:
            if (_isConnected) {
              continue continueThis;
            }
            break;
          continueThis:
          case BluetoothManager.CONNECTED:
            _isConnected = true;

            if (hasWritten) {
              break;
            }
            hasWritten = true;

            try {
              await writeChunked();
            } catch (e) {
              if (e is PlatformException && e.code == 'not_connected') {
                _isConnected = false;
              }
              finish(PosPrintResult.timeout);
              break;
            }

            if (isFinished) {
              break;
            }

            _armDisconnectTimer();

            finish(PosPrintResult.success);
            break;
          case BluetoothManager.DISCONNECTED:
            _isConnected = false;
            break;
          default:
            break;
        }
      });
    }

    // Printing timeout
    timeoutTimer = Timer(Duration(seconds: timeout), () {
      finish(PosPrintResult.timeout);
    });

    return completer.future;
  }

  // TODO sending disconnect signal should be event-based
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
      // We initiated this disconnect, so mark the connection closed for all
      // profiles. Leaving _isConnected true made the next job skip connect()
      // and wait for a CONNECTED event that never arrives.
      _isConnected = false;
    }
    _pendingDisconnect = null;
  }

  Future<PosPrintResult> printTicket(
    List<int> bytes, {
    int chunkSizeBytes = 20,
    int queueSleepTimeMs = 20,
  }) async {
    if (bytes.isEmpty) {
      return Future<PosPrintResult>.value(PosPrintResult.ticketEmpty);
    }
    return writeBytes(
      bytes,
      chunkSizeBytes: chunkSizeBytes,
      queueSleepTimeMs: queueSleepTimeMs,
    );
  }

  Future<bool> _bluetoothDisconnectSuccess() async {
    final Completer<bool> completer = Completer();
    StreamSubscription<int?>? stateSubscription;
    Timer? timeoutTimer;

    void finish(bool result) {
      timeoutTimer?.cancel();
      stateSubscription?.cancel();
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    stateSubscription = _bluetoothManager.state.listen((state) {
      if (state == BluetoothManager.DISCONNECTED) {
        finish(true);
      }
    });

    timeoutTimer = Timer(Duration(seconds: 5), () {
      finish(false);
    });

    return completer.future;
  }
}
