import 'dart:async';

import '../platform_telemetry.dart';

/// Deterministic [PlatformTelemetry] backed by broadcast controllers so tests
/// can push thermal / battery events on demand.
class FakePlatformTelemetry implements PlatformTelemetry {
  final _thermal = StreamController<DeviceThermalState>.broadcast();
  final _battery = StreamController<BatteryStatus>.broadcast();

  @override
  Stream<DeviceThermalState> get thermalState => _thermal.stream;

  @override
  Stream<BatteryStatus> get battery => _battery.stream;

  void emitThermal(DeviceThermalState state) => _thermal.add(state);

  void emitBattery(BatteryStatus status) => _battery.add(status);

  @override
  Future<void> dispose() async {
    await _thermal.close();
    await _battery.close();
  }
}
