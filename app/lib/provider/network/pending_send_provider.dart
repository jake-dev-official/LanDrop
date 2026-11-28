import 'dart:async';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
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
  final bool waitingForBusy;
  final bool background;

  const PendingSendEntry({
    required this.id,
    required this.targetFingerprint,
    required this.targetAlias,
    required this.targetDevice,
    required this.files,
    required this.queuedAt,
    required this.expiresAt,
    this.waitingForBusy = false,
    this.background = true,
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

  bool _hasActiveSendSession() {
    return ref
        .read(sendProvider)
        .values
        .any(
          (s) => s.status == SessionStatus.sending || s.status == SessionStatus.waiting,
        );
  }

  /// Queues [files] for [target] for up to [ttl] (defaults to 5 minutes).
  /// Returns `true` if queued to wait (target offline or another transfer is active),
  /// or `false` if [target] was online, idle, and sending began immediately.
  Future<bool> enqueue({
    required Device target,
    required List<CrossFile> files,
    Duration ttl = const Duration(minutes: 5),
    bool background = true,
  }) async {
    if (files.isEmpty) {
      return false;
    }

    final busy = _hasActiveSendSession();
    final online = ref.read(nearbyDevicesProvider).devices[target.fingerprint];
    final isTargetOnline = online != null && (online.ip?.isNotEmpty ?? false);
    if (!busy && isTargetOnline) {
      unawaited(ref.notifier(sendProvider).startSession(target: online, files: files, background: background));
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
      expiresAt: now.add(busy ? const Duration(minutes: 30) : ttl),
      waitingForBusy: busy && isTargetOnline,
      background: background,
    );
    state = List<PendingSendEntry>.unmodifiable([...state, entry]);
    _ensureTimer();
    if (!busy) {
      unawaited(_probePendingDevices());
    }
    return true;
  }

  void onSendSessionIdle() {
    if (state.isEmpty || _hasActiveSendSession()) {
      return;
    }

    final now = DateTime.now();
    final valid = state.where((e) => !now.isAfter(e.expiresAt)).toList();
    if (valid.length != state.length) {
      state = List<PendingSendEntry>.unmodifiable(valid);
    }
    if (valid.isEmpty) {
      _stopTimer();
      return;
    }

    final nearby = ref.read(nearbyDevicesProvider).devices;
    PendingSendEntry? nextEntry;
    Device? nextTarget;
    for (final entry in valid) {
      final online = nearby[entry.targetFingerprint];
      if (online != null && (online.ip?.isNotEmpty ?? false)) {
        nextEntry = entry;
        nextTarget = online;
        break;
      }
    }

    if (nextEntry == null || nextTarget == null) {
      return;
    }

    state = List<PendingSendEntry>.unmodifiable(valid.where((e) => e.id != nextEntry!.id));
    if (state.isEmpty) {
      _stopTimer();
    }

    unawaited(
      ref
          .notifier(sendProvider)
          .startSession(
            target: nextTarget,
            files: nextEntry.files,
            background: nextEntry.background,
          ),
    );
  }

  void onDeviceOnline(Device device) {
    if (state.isEmpty || _hasActiveSendSession()) {
      return;
    }
    final now = DateTime.now();
    final valid = state.where((e) => !now.isAfter(e.expiresAt)).toList();
    final matchIndex = valid.indexWhere((e) => e.targetFingerprint == device.fingerprint);
    if (matchIndex == -1) {
      if (valid.length != state.length) {
        state = List<PendingSendEntry>.unmodifiable(valid);
      }
      if (state.isEmpty) {
        _stopTimer();
      }
      return;
    }

    final matched = valid[matchIndex];
    final remaining = [
      for (int i = 0; i < valid.length; i++)
        if (i != matchIndex) valid[i],
    ];

    state = List<PendingSendEntry>.unmodifiable(remaining);
    if (state.isEmpty) {
      _stopTimer();
    }

    unawaited(
      ref
          .notifier(sendProvider)
          .startSession(
            target: device,
            files: matched.files,
            background: matched.background,
          ),
    );
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

    if (_hasActiveSendSession()) {
      return;
    }

    final nearby = ref.read(nearbyDevicesProvider);
    for (final entry in active) {
      final online = nearby.devices[entry.targetFingerprint];
      if (online != null && (online.ip?.isNotEmpty ?? false)) {
        onSendSessionIdle();
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
