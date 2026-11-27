import 'package:localsend_isolates/constants.dart';
import 'package:localsend_isolates/model/device.dart';

class KnownDevice {
  final String fingerprint;
  final String alias;
  final String ip;
  final int port;
  final bool https;
  final DeviceType deviceType;
  final int lastSeenMs;

  const KnownDevice({
    required this.fingerprint,
    required this.alias,
    required this.ip,
    required this.port,
    required this.https,
    required this.deviceType,
    required this.lastSeenMs,
  });

  KnownDevice copyWith({
    String? fingerprint,
    String? alias,
    String? ip,
    int? port,
    bool? https,
    DeviceType? deviceType,
    int? lastSeenMs,
  }) {
    return KnownDevice(
      fingerprint: fingerprint ?? this.fingerprint,
      alias: alias ?? this.alias,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      https: https ?? this.https,
      deviceType: deviceType ?? this.deviceType,
      lastSeenMs: lastSeenMs ?? this.lastSeenMs,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fingerprint': fingerprint,
      'alias': alias,
      'ip': ip,
      'port': port,
      'https': https,
      'deviceType': deviceType.name,
      'lastSeenMs': lastSeenMs,
    };
  }

  factory KnownDevice.fromJson(Map<String, dynamic> json) {
    final typeName = json['deviceType'] as String?;
    final deviceType = DeviceType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => DeviceType.mobile,
    );
    return KnownDevice(
      fingerprint: json['fingerprint'] as String? ?? '',
      alias: json['alias'] as String? ?? 'LanDrop Device',
      ip: json['ip'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? defaultPort,
      https: json['https'] as bool? ?? true,
      deviceType: deviceType,
      lastSeenMs: (json['lastSeenMs'] as num?)?.toInt() ?? 0,
    );
  }

  Device toDevice() {
    return Device(
      signalingId: null,
      ip: ip,
      version: protocolVersion,
      port: port,
      https: https,
      fingerprint: fingerprint,
      alias: alias,
      deviceModel: null,
      deviceType: deviceType,
      download: false,
      channels: [
        HttpChannel(host: ip, port: port, https: https),
      ],
    );
  }
}
