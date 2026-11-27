import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/known_device.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:logging/logging.dart';

final _logger = Logger('WindowsDeviceCache');

String getWindowsDeviceCachePath() {
  final userProfile = Platform.environment['USERPROFILE'] ?? '';
  if (userProfile.isNotEmpty) {
    return '$userProfile\\.landrop\\devices.json';
  }
  final appData = Platform.environment['APPDATA'] ?? '';
  return '$appData\\LanDrop\\devices.json';
}

Map<String, dynamic> buildDeviceCachePayload({
  required String exePath,
  required List<FavoriteDevice> favorites,
  required Map<String, Device> nearbyDevices,
  List<KnownDevice> knownDevices = const [],
}) {
  final favByFp = {
    for (final fav in favorites) fav.fingerprint: fav,
  };
  final knownByFp = {
    for (final known in knownDevices) known.fingerprint: known,
  };
  final allFingerprints = <String>{
    ...favByFp.keys,
    ...nearbyDevices.keys,
    ...knownByFp.keys,
  };

  final entries = <Map<String, dynamic>>[];
  for (final fp in allFingerprints) {
    final fav = favByFp[fp];
    final online = nearbyDevices[fp];
    final known = knownByFp[fp];
    if (fav == null && online == null && known == null) {
      continue;
    }

    final isOnline = online != null && (online.ip?.isNotEmpty ?? false);
    final isFavorite = fav != null;
    final alias = fav != null ? (fav.customAlias || online == null ? fav.alias : online.alias) : (online?.alias ?? known!.alias);
    final ip = (online?.ip?.isNotEmpty ?? false) ? online!.ip! : (fav?.ip ?? known?.ip);
    if (ip == null || ip.isEmpty) {
      continue;
    }

    entries.add({
      'fingerprint': fp,
      'alias': alias,
      'ip': ip,
      'port': online?.port ?? fav?.port ?? known!.port,
      'https': online?.https ?? known?.https ?? true,
      'online': isOnline,
      'favorite': isFavorite,
    });
  }

  entries.sort((a, b) {
    final rankA = _rankEntry(a);
    final rankB = _rankEntry(b);
    if (rankA != rankB) {
      return rankA.compareTo(rankB);
    }
    return (a['alias'] as String).toLowerCase().compareTo((b['alias'] as String).toLowerCase());
  });

  return {
    'exePath': exePath,
    'devices': entries,
  };
}

int _rankEntry(Map<String, dynamic> entry) {
  final online = entry['online'] == true;
  final favorite = entry['favorite'] == true;
  if (online && favorite) return 0;
  if (online) return 1;
  if (favorite) return 2;
  return 3;
}

Future<void> syncWindowsDeviceCache({
  required List<FavoriteDevice> favorites,
  required Map<String, Device> nearbyDevices,
  List<KnownDevice> knownDevices = const [],
}) async {
  if (defaultTargetPlatform != TargetPlatform.windows) {
    return;
  }

  try {
    final cachePath = getWindowsDeviceCachePath();
    final file = File(cachePath);
    await file.parent.create(recursive: true);

    final payload = buildDeviceCachePayload(
      exePath: Platform.resolvedExecutable,
      favorites: favorites,
      nearbyDevices: nearbyDevices,
      knownDevices: knownDevices,
    );
    final tmpFile = File('$cachePath.tmp');
    await tmpFile.writeAsString(jsonEncode(payload), flush: true);
    await tmpFile.rename(cachePath);
  } catch (e) {
    _logger.warning('Failed to sync Windows device cache: $e');
  }
}
