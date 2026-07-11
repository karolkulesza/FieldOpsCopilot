/// Abstraction over native device telemetry used to govern inference.
library;

/// Normalised device thermal state, mapped from the underlying platform
/// (iOS `ProcessInfo.thermalState` / Android `PowerManager` headroom).
enum DeviceThermalState { nominal, fair, serious, critical }

/// Battery snapshot. [level] is in the range 0.0–1.0.
class BatteryStatus {
  const BatteryStatus({required this.level, required this.isCharging});

  final double level;
  final bool isCharging;

  @override
  String toString() =>
      'BatteryStatus(${(level * 100).round()}%, charging: $isCharging)';
}

/// Contract implemented by every telemetry backend (fake or native).
abstract interface class PlatformTelemetry {
  Stream<DeviceThermalState> get thermalState;

  Stream<BatteryStatus> get battery;

  Future<void> dispose();
}
