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
  Timer _timeoutTimer = Timer(Duration.zero, () {});
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
    }
    // else if (_isPrinting) {
    //   return Future<PosPrintResult>.value(PosPrintResult.printInProgress);
    // }

    _isPrinting = true;

    if (_changeConnection) {
      // print('changeConnection: $_changeConnection');
      _changeConnection = false;
      if (_disconnectBluetoothTimer.isActive) {
        _disconnectBluetoothTimer.cancel();
      }

      if (_isConnected) {
        // print('_isConnected: $_isConnected');
        await _bluetoothManager.disconnect();

        if (Platform.isAndroid) {
          final bool _isBluetoothDisconnectSuccess = await _bluetoothDisconnectSuccess();

          // _isBluetoothDisconnectSuccess is still not utilize
          // if (_isBluetoothDisconnectSuccess) {
          //   print('success');
          // } else {
          //   print('failed');
          // }
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

    // ISSUE WITH IOS, PRINT MULTIPLE TIMES
    if (Platform.isAndroid) {
      // Subscribe to the events
      _bluetoothManager.state.listen((state) async {
        switch (state) {
          case 12:
            if (_isConnected) {
              continue continueThis;
            }

            if (_capabilityProfile != null && _capabilityProfile!.name == 'IMIN-USB') {
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

            _disconnectBluetoothTimer = Timer(Duration(seconds: 10), () async {
              // print('disconnectBluetoothTimer');
              if (_isConnected) {
                // print('disconnect');
                await _bluetoothManager.disconnect();

                if (_capabilityProfile != null && _capabilityProfile!.name == 'IMIN-USB') {
                  _isConnected = false;
                }
              }
            });

            // _runDelayed(1000).then((dynamic v) async {
            //   await _bluetoothManager.disconnect();
            //   _isPrinting = false;
            // });

            // _isConnected = true;
            break;
          case BluetoothManager.DISCONNECTED:
            // print('disconnected');
            _isConnected = false;
            break;
          default:
            break;
        }
      });
    } else if (Platform.isIOS) {
      // Subscribe to the events
      _bluetoothManager.state.listen((state) async {
        // print('state: $state');
        // print('_isConnected: $_isConnected');
        // print('_isPrinting: $_isPrinting');
        switch (state) {
          case null:
            if (_isConnected) {
              continue continueThis;
            }
            break;
          continueThis:
          case BluetoothManager.CONNECTED:
            _isConnected = true;

            if (_isPrinting == true) {
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
            }

            // print('success');
            completer.complete(PosPrintResult.success);
            _isPrinting = false;

            // TODO sending disconnect signal should be event-based
            if (_disconnectBluetoothTimer.isActive) {
              _disconnectBluetoothTimer.cancel();
            }

            _disconnectBluetoothTimer = Timer(Duration(seconds: 10), () async {
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
    }

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

  Future<bool> _bluetoothDisconnectSuccess() async {
    final Completer<bool> completer = Completer();

    if (Platform.isAndroid) {
      // Subscribe to the events
      _bluetoothManager.state.listen((state) async {
        switch (state) {
          case BluetoothManager.DISCONNECTED:
            completer.complete(true);
            break;
          default:
            break;
        }
      });
    }

    _timeoutTimer = Timer(Duration(seconds: 5), () async {
      completer.complete(false);
    });

    return completer.future;
  }
}
