import 'dart:async';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class PendingSendEntry {
  final String id;
  final String targetFingerprint;
  final String targetAlias;
  final Device targetDevice;
  final List<CrossFile> files;
  final DateTime queuedAt;
  final DateTime expiresAt;

  const PendingSendEntry({
    required this.id,
    required this.targetFingerprint,
    required this.targetAlias,
    required this.targetDevice,
    required this.files,
    required this.queuedAt,
    required this.expiresAt,
  });
}

final NotifierProvider<PendingSendNotifier, List<PendingSendEntry>> pendingSendProvider =
    NotifierProvider<PendingSendNotifier, List<PendingSendEntry>>(
      (ref) => PendingSendNotifier(),
    );

class PendingSendNotifier extends Notifier<List<PendingSendEntry>> {
  Timer? _retryTimer;

  @override
  List<PendingSendEntry> init() => const [];

  @override
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    super.dispose();
  }

  /// Queues [files] for [target] for up to [ttl] (defaults to 5 minutes).
  /// Returns `true` if queued to wait, or `false` if [target] was already online and sending began immediately.
  Future<bool> enqueue({
    required Device target,
    required List<CrossFile> files,
    Duration ttl = const Duration(minutes: 5),
  }) async {
    if (files.isEmpty) {
      return false;
    }

    final online = ref.read(nearbyDevicesProvider).devices[target.fingerprint];
    if (online != null && (online.ip?.isNotEmpty ?? false)) {
      await ref.notifier(sendProvider).startSession(target: online, files: files, background: true);
      return false;
    }

    final now = DateTime.now();
    final entry = PendingSendEntry(
      id: _uuid.v4(),
      targetFingerprint: target.fingerprint,
      targetAlias: target.alias,
      targetDevice: target,
      files: List<CrossFile>.unmodifiable(files),
      queuedAt: now,
      expiresAt: now.add(ttl),
    );
    state = List<PendingSendEntry>.unmodifiable([...state, entry]);
    _ensureTimer();
    unawaited(_probePendingDevices());
    return true;
  }

  void onDeviceOnline(Device device) {
    if (state.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final matched = <PendingSendEntry>[];
    final remaining = <PendingSendEntry>[];

    for (final entry in state) {
      if (now.isAfter(entry.expiresAt)) {
        continue;
      }
      if (entry.targetFingerprint == device.fingerprint) {
        matched.add(entry);
      } else {
        remaining.add(entry);
      }
    }

    state = List<PendingSendEntry>.unmodifiable(remaining);
    if (state.isEmpty) {
      _stopTimer();
    }

    for (final entry in matched) {
      unawaited(
        ref
            .notifier(sendProvider)
            .startSession(
              target: device,
              files: entry.files,
              background: true,
            ),
      );
    }
  }

  void cancel(String id) {
    state = List<PendingSendEntry>.unmodifiable(state.where((e) => e.id != id));
    if (state.isEmpty) {
      _stopTimer();
    }
  }

  void _ensureTimer() {
    if (_retryTimer != null) {
      return;
    }
    _retryTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_probePendingDevices());
    });
  }

  void _stopTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _probePendingDevices() async {
    final now = DateTime.now();
    final active = state.where((e) => !now.isAfter(e.expiresAt)).toList();
    if (active.length != state.length) {
      state = List<PendingSendEntry>.unmodifiable(active);
    }
    if (active.isEmpty) {
      _stopTimer();
      return;
    }

    final nearby = ref.read(nearbyDevicesProvider);
    for (final entry in active) {
      final online = nearby.devices[entry.targetFingerprint];
      if (online != null && (online.ip?.isNotEmpty ?? false)) {
        onDeviceOnline(online);
        return;
      }
    }

    if (nearby.runningFavoriteScan) {
      return;
    }

    ref.redux(nearbyDevicesProvider).dispatch(StartMulticastScan());
    final probeTargets = <String, FavoriteDevice>{};
    for (final entry in active) {
      final ip = entry.targetDevice.ip;
      if (ip == null || ip.isEmpty) {
        continue;
      }
      probeTargets[entry.targetFingerprint] = FavoriteDevice.fromValues(
        fingerprint: entry.targetFingerprint,
        ip: ip,
        port: entry.targetDevice.port,
        alias: entry.targetAlias,
      );
    }
    if (probeTargets.isEmpty) {
      return;
    }

    final settings = ref.read(settingsProvider);
    final interfaces = ref.read(localIpProvider).localIps.take(3).toList();
    await ref
        .redux(nearbyDevicesProvider)
        .dispatchAsync(
          StartStagedScan(
            favorites: probeTargets.values.toList(),
            interfaces: interfaces,
            port: settings.port,
            https: settings.https,
            grace: const Duration(milliseconds: 500),
          ),
        );
  }
}
