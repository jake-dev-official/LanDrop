import 'dart:async';

import 'package:localsend_app/model/persistence/known_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/native/android_share_shortcuts.dart';
import 'package:localsend_app/util/native/windows_device_cache.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

const _maxKnownDevices = 20;

final ReduxProvider<KnownDevicesService, List<KnownDevice>> knownDevicesProvider = ReduxProvider<KnownDevicesService, List<KnownDevice>>(
  (ref) {
    return KnownDevicesService(ref.read(persistenceProvider));
  },
  onChanged: (_, next, ref) {
    final favorites = ref.read(favoritesProvider);
    final nearby = ref.read(nearbyDevicesProvider).devices;
    unawaited(
      syncWindowsDeviceCache(
        favorites: favorites,
        nearbyDevices: nearby,
        knownDevices: next,
      ),
    );
    unawaited(
      syncAndroidShareShortcuts(
        favorites: favorites,
        nearbyDevices: nearby,
        knownDevices: next,
      ),
    );
  },
);

class KnownDevicesService extends ReduxNotifier<List<KnownDevice>> {
  final PersistenceService _persistence;

  KnownDevicesService(this._persistence);

  @override
  List<KnownDevice> init() => _persistence.getKnownDevices();
}

class RememberDeviceAction extends AsyncReduxAction<KnownDevicesService, List<KnownDevice>> {
  final Device device;

  RememberDeviceAction(this.device);

  @override
  bool get trackOrigin => false;

  @override
  Future<List<KnownDevice>> reduce() async {
    final ip = device.ip;
    if (ip == null || ip.isEmpty || device.fingerprint.isEmpty) {
      return state;
    }

    final entry = KnownDevice(
      fingerprint: device.fingerprint,
      alias: device.alias,
      ip: ip,
      port: device.port,
      https: device.https,
      deviceType: device.deviceType,
      lastSeenMs: DateTime.now().millisecondsSinceEpoch,
    );

    final updated = [
      entry,
      ...state.where((e) => e.fingerprint != device.fingerprint && e.ip != ip),
    ].take(_maxKnownDevices).toList();
    final unmodifiable = List<KnownDevice>.unmodifiable(updated);
    await notifier._persistence.setKnownDevices(unmodifiable);
    return unmodifiable;
  }
}

class RemoveKnownDeviceAction extends AsyncReduxAction<KnownDevicesService, List<KnownDevice>> {
  final String fingerprint;

  RemoveKnownDeviceAction(this.fingerprint);

  @override
  Future<List<KnownDevice>> reduce() async {
    final updated = List<KnownDevice>.unmodifiable(
      state.where((e) => e.fingerprint != fingerprint),
    );
    await notifier._persistence.setKnownDevices(updated);
    return updated;
  }
}
