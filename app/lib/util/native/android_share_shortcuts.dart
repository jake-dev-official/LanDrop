import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/known_device.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:logging/logging.dart';

final _logger = Logger('AndroidShareShortcuts');
Future<void> _shortcutChain = Future<void>.value();
String? _lastPushedShortcutsJson;

List<Map<String, dynamic>> buildAndroidShareShortcutsPayload({
  required List<FavoriteDevice> favorites,
  required Map<String, Device> nearbyDevices,
  List<KnownDevice> knownDevices = const [],
  int maxCount = 4,
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
    if (fp.isEmpty) {
      continue;
    }
    final fav = favByFp[fp];
    final online = nearbyDevices[fp];
    final known = knownByFp[fp];
    if (fav == null && online == null && known == null) {
      continue;
    }

    final isOnline = online != null && (online.ip?.isNotEmpty ?? false);
    final isFavorite = fav != null;
    final alias = fav != null ? (fav.customAlias || online == null ? fav.alias : online.alias) : (online?.alias ?? known!.alias);
    final deviceType = (online?.deviceType ?? known?.deviceType ?? DeviceType.desktop).name;

    entries.add({
      'fingerprint': fp,
      'alias': alias,
      'deviceType': deviceType,
      '_online': isOnline,
      '_favorite': isFavorite,
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

  return entries
      .take(maxCount)
      .map(
        (e) => <String, dynamic>{
          'fingerprint': e['fingerprint'],
          'alias': e['alias'],
          'deviceType': e['deviceType'],
        },
      )
      .toList();
}

int _rankEntry(Map<String, dynamic> entry) {
  final online = entry['_online'] == true;
  final favorite = entry['_favorite'] == true;
  if (online && favorite) return 0;
  if (online) return 1;
  if (favorite) return 2;
  return 3;
}

Future<void> syncAndroidShareShortcuts({
  required List<FavoriteDevice> favorites,
  required Map<String, Device> nearbyDevices,
  List<KnownDevice> knownDevices = const [],
}) {
  if (defaultTargetPlatform != TargetPlatform.android) {
    return Future<void>.value();
  }

  final payload = buildAndroidShareShortcutsPayload(
    favorites: favorites,
    nearbyDevices: nearbyDevices,
    knownDevices: knownDevices,
  );
  final encoded = jsonEncode(payload);

  _shortcutChain = _shortcutChain.then((_) async {
    if (encoded == _lastPushedShortcutsJson) {
      return;
    }
    try {
      await updateShareShortcutsAndroid(payload);
      _lastPushedShortcutsJson = encoded;
    } catch (e) {
      _logger.warning('Failed to sync Android Share shortcuts: $e');
    }
  });
  return _shortcutChain;
}
