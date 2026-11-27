import 'dart:async';

import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/known_devices_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Discovers devices in stages, cheapest first: multicast announcement and
/// favorite/known-device probes right away, http-based discovery on the subnets only when
/// nothing was confirmed within 1 second.
class StartSmartScan extends AsyncGlobalAction {
  /// Maximum number of interfaces to scan.
  /// If there are more interfaces, the first ones will be used or the user needs to select one.
  static const maxInterfaces = 3;

  @override
  Future<void> reduce() async {
    final favorites = ref.read(favoritesProvider);
    final known = ref.read(knownDevicesProvider);
    final settings = ref.read(settingsProvider);
    final networkInterfaces = ref.read(localIpProvider).localIps.take(maxInterfaces).toList();
    if (networkInterfaces.isEmpty) {
      return;
    }

    final probeByFingerprint = <String, FavoriteDevice>{
      for (final f in favorites) f.fingerprint: f,
    };
    for (final k in known) {
      probeByFingerprint.putIfAbsent(
        k.fingerprint,
        () => FavoriteDevice.fromValues(
          fingerprint: k.fingerprint,
          ip: k.ip,
          port: k.port,
          alias: k.alias,
        ),
      );
    }

    await ref
        .redux(nearbyDevicesProvider)
        .dispatchAsync(
          StartStagedScan(
            favorites: probeByFingerprint.values.toList(),
            interfaces: networkInterfaces,
            port: settings.port,
            https: settings.https,
            grace: const Duration(seconds: 1),
          ),
        );
  }
}

/// HTTP based discovery on a fixed set of subnets.
class StartLegacySubnetScan extends AsyncGlobalAction {
  final List<String> subnets;

  StartLegacySubnetScan({
    required this.subnets,
  });

  @override
  Future<void> reduce() async {
    final settings = ref.read(settingsProvider);
    final port = settings.port;
    final https = settings.https;

    // send announcement in parallel
    ref.redux(nearbyDevicesProvider).dispatch(StartMulticastScan());

    await Future.wait<void>([
      for (final subnet in subnets) ref.redux(nearbyDevicesProvider).dispatchAsync(StartLegacyScan(port: port, localIp: subnet, https: https)),
    ]);
  }
}
