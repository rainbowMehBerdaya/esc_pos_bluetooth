/*
 * esc_pos_bluetooth
 * Created by Andrey Ushakov
 *
 * Copyright (c) 2019-2020. All rights reserved.
 * See LICENSE for distribution and usage details.
 */

import 'dart:async';
import 'dart:io';

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
}

/// Printer Bluetooth Manager
class PrinterBluetoothManager {
  final BluetoothManager _bluetoothManager = BluetoothManager.instance;
  Timer _disconnectBluetoothTimer = Timer(Duration.zero, () {});
  Timer _timeoutTimer = Timer(Duration.zero, () {});
  bool _isPrinting = false;
  bool _isConnected = false;
  bool _supportBLE = true;
  StreamSubscription? _scanResultsSubscription;
  StreamSubscription? _isScanningSubscription;
  PrinterBluetooth? _selectedPrinter;

  bool get supportBLE => _supportBLE;
  final BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);

  Stream<bool> get isScanningStream => _isScanning.stream;
  final BehaviorSubject<List<PrinterBluetooth>> _scanResults = BehaviorSubject.seeded([]);

  Stream<List<PrinterBluetooth>> get scanResults => _scanResults.stream;
  final BehaviorSubject<List<PrinterBluetooth>> _scanResultsNonScan = BehaviorSubject.seeded([]);

  Stream<List<PrinterBluetooth>> get scanResultsNonScan => _scanResultsNonScan.stream;

  // Future _runDelayed(int seconds) {
  //   return Future<dynamic>.delayed(Duration(seconds: seconds));
  // }

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
      // _supportBLE = false;
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

  void selectPrinter(PrinterBluetooth printer) {
    _selectedPrinter = printer;
  }

  Future<PosPrintResult> writeBytes(
    List<int> bytes, {
    int chunkSizeBytes = 20,
    int queueSleepTimeMs = 20,
  }) async {
    final Completer<PosPrintResult> completer = Completer();

    const int timeout = 5;
    if (_selectedPrinter == null) {
      return Future<PosPrintResult>.value(PosPrintResult.printerNotSelected);
    } else if (_isScanning.value) {
      return Future<PosPrintResult>.value(PosPrintResult.scanInProgress);
    }
    // else if (_isPrinting) {
    //   return Future<PosPrintResult>.value(PosPrintResult.printInProgress);
    // }

    _isPrinting = true;

    if (!_isConnected) {
      if (supportBLE) {
        // We have to rescan before connecting, otherwise we can connect only once
        await _bluetoothManager.startScan(timeout: Duration(seconds: 1));
        await _bluetoothManager.stopScan();
      }

      // Connect
      await _bluetoothManager.connect(_selectedPrinter!._device);
    }

    // Subscribe to the events
    _bluetoothManager.state.listen((state) async {
      // print('state: $state');
      switch (state) {
        case 12:
          if (_isConnected) {
            continue continueThis;
          }
          break;
        continueThis:
        case BluetoothManager.CONNECTED:
          _isConnected = true;

          final len = bytes.length;
          List<List<int>> chunks = [];
          for (var i = 0; i < len; i += chunkSizeBytes) {
            var end = (i + chunkSizeBytes < len) ? i + chunkSizeBytes : len;
            chunks.add(bytes.sublist(i, end));
          }

          for (var i = 0; i < chunks.length; i += 1) {
            await _bluetoothManager.writeData(chunks[i]);
            sleep(Duration(milliseconds: queueSleepTimeMs));
          }

          // print('success');
          completer.complete(PosPrintResult.success);
          _isPrinting = false;

          // TODO sending disconnect signal should be event-based
          if (_disconnectBluetoothTimer.isActive) {
            _disconnectBluetoothTimer.cancel();
          }

          _disconnectBluetoothTimer = Timer(Duration(seconds: 3), () async {
            // print('disconnectBluetoothTimer');
            if (_isConnected) {
              // print('disconnect');
              await _bluetoothManager.disconnect();
            }
          });

          // _runDelayed(1000).then((dynamic v) async {
          //   await _bluetoothManager.disconnect();
          //   _isPrinting = false;
          // });

          // _isConnected = true;
          break;
        case BluetoothManager.DISCONNECTED:
          _isConnected = false;
          break;
        default:
          break;
      }
    });

    // Printing timeout
    if (_timeoutTimer.isActive) {
      _timeoutTimer.cancel();
    }

    _timeoutTimer = Timer(Duration(seconds: timeout), () async {
      // print('timeoutTimer');
      // print('_isPrinting: $_isPrinting');
      if (_isPrinting) {
        _isPrinting = false;
        // print('timeout');
        completer.complete(PosPrintResult.timeout);
      }
    });

    // _runDelayed(timeout).then((dynamic v) async {
    //   if (_isPrinting) {
    //     _isPrinting = false;
    //     completer.complete(PosPrintResult.timeout);
    //   }
    // });

    return completer.future;
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
}
