import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:localsend_app/util/native/directories.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('CompletionSound');
const _windowsChannel = MethodChannel('org.localsend.localsend_app/landrop_windows');
const incomingSoundAsset = 'assets/sound/incoming_ping.wav';
const completeSoundAsset = 'assets/sound/complete_marimba.wav';
const _minIncomingToFinishGapMs = 340;

final Map<String, String> _cachedAssetPaths = {};
DateTime? _lastIncomingSoundAt;
int _soundEpoch = 0;

void cancelPendingFinishSound() {
  _soundEpoch++;
}

Future<void> playTransferIncomingSound() async {
  _lastIncomingSoundAt = DateTime.now();
  await _playAssetSound(incomingSoundAsset);
}

Future<void> playTransferFinishSound({bool respectIncomingGap = true}) async {
  final epoch = _soundEpoch;
  if (respectIncomingGap && _lastIncomingSoundAt != null) {
    final elapsedMs = DateTime.now().difference(_lastIncomingSoundAt!).inMilliseconds;
    if (elapsedMs < _minIncomingToFinishGapMs) {
      await Future.delayed(Duration(milliseconds: _minIncomingToFinishGapMs - elapsedMs));
    }
  }
  if (epoch != _soundEpoch) {
    return;
  }
  await _playAssetSound(completeSoundAsset);
}

/// Extracts the bundled sound lazily and plays it natively without extra packages.
Future<void> playCompletionSound() async {
  await playTransferFinishSound(respectIncomingGap: false);
}

Future<void> _playAssetSound(String assetPath) async {
  try {
    final path = await _ensureAssetSoundFile(assetPath);
    if (path == null) {
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await _windowsChannel.invokeMethod<void>('playCompletionSound', {'path': path});
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      await playCompletionSoundAndroid(path);
    }
  } catch (e) {
    _logger.fine('Failed to play transfer sound: $e');
  }
}

Future<String?> _ensureAssetSoundFile(String assetPath) async {
  final existing = _cachedAssetPaths[assetPath];
  if (existing != null && await File(existing).exists()) {
    return existing;
  }

  final String dir;
  if (defaultTargetPlatform == TargetPlatform.windows) {
    dir = Directory.systemTemp.path;
  } else if (defaultTargetPlatform == TargetPlatform.android) {
    dir = await getCacheDirectory();
  } else {
    return null;
  }

  final fileName = 'landrop_${p.basename(assetPath)}';
  final file = File(p.join(dir, fileName));
  if (!await file.exists()) {
    final data = await rootBundle.load(assetPath);
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }
  _cachedAssetPaths[assetPath] = file.path;
  return file.path;
}
