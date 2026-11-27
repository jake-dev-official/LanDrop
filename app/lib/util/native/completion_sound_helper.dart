import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:localsend_app/util/native/directories.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;

final _logger = Logger('CompletionSound');
const _windowsChannel = MethodChannel('org.localsend.localsend_app/landrop_windows');
const transferSoundPresets = ['default', 'pop', 'blip', 'chime', 'ding', 'custom'];

final Map<String, String> _cachedAssetPaths = {};
DateTime? _lastStartSoundAt;
int _soundEpoch = 0;

void cancelPendingFinishSound() {
  _soundEpoch++;
}

String transferSoundPresetLabel(String preset) {
  switch (preset) {
    case 'default':
      return 'Default';
    case 'pop':
      return 'Pop';
    case 'blip':
      return 'Blip';
    case 'chime':
      return 'Chime';
    case 'ding':
      return 'Ding';
    case 'custom':
      return 'Custom file';
    default:
      return 'Default';
  }
}

String resolveTransferSoundAsset({
  required String preset,
  required bool isStart,
}) {
  switch (preset) {
    case 'pop':
      return isStart ? 'assets/sound/pop_start.wav' : 'assets/sound/pop.wav';
    case 'blip':
      return isStart ? 'assets/sound/blip_start.wav' : 'assets/sound/blip_done.wav';
    case 'chime':
      return isStart ? 'assets/sound/chime_start.wav' : 'assets/sound/chime_done.wav';
    case 'ding':
      return isStart ? 'assets/sound/ding_start.wav' : 'assets/sound/ding_done.wav';
    case 'default':
    default:
      return isStart ? 'assets/sound/pop_start.wav' : 'assets/sound/default.wav';
  }
}

Future<void> playTransferStartSound({
  required String preset,
  String? customPath,
}) async {
  _lastStartSoundAt = DateTime.now();
  await _playConfiguredSound(
    preset: preset,
    customPath: customPath,
    isStart: true,
  );
}

Future<void> playTransferFinishSound({
  required String preset,
  String? customPath,
  bool respectStartGap = true,
}) async {
  final epoch = _soundEpoch;
  if (respectStartGap && _lastStartSoundAt != null) {
    final elapsedMs = DateTime.now().difference(_lastStartSoundAt!).inMilliseconds;
    if (elapsedMs < 320) {
      await Future.delayed(Duration(milliseconds: 320 - elapsedMs));
    }
  }
  if (epoch != _soundEpoch) {
    return;
  }
  await _playConfiguredSound(
    preset: preset,
    customPath: customPath,
    isStart: false,
  );
}

/// Extracts the bundled pop sound lazily and plays it natively without extra packages.
Future<void> playCompletionSound() async {
  await playTransferFinishSound(preset: 'default', respectStartGap: false);
}

Future<String?> pickAndSaveCustomSoundFile() async {
  final XTypeGroup typeGroup;
  if (defaultTargetPlatform == TargetPlatform.windows) {
    typeGroup = const XTypeGroup(
      label: 'WAV audio',
      extensions: ['wav'],
    );
  } else {
    typeGroup = const XTypeGroup(
      label: 'Audio',
      mimeTypes: ['audio/*'],
      extensions: ['wav', 'mp3', 'ogg', 'm4a'],
    );
  }

  final picked = await openFile(acceptedTypeGroups: [typeGroup]);
  if (picked == null) {
    return null;
  }

  final bytes = await picked.readAsBytes();
  final rawExt = p.extension(picked.name).replaceFirst('.', '').toLowerCase();
  final ext = rawExt.isEmpty ? 'wav' : rawExt;
  final dir = await path_provider.getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final destFile = File(p.join(dir.path, 'landrop_custom_sound.$ext'));
  await destFile.writeAsBytes(bytes, flush: true);
  return destFile.path;
}

Future<void> _playConfiguredSound({
  required String preset,
  required String? customPath,
  required bool isStart,
}) async {
  try {
    String? path;
    if (preset == 'custom' && customPath != null && customPath.isNotEmpty) {
      final customFile = File(customPath);
      if (await customFile.exists()) {
        path = customFile.path;
      }
    }
    path ??= await _ensureAssetSoundFile(
      resolveTransferSoundAsset(preset: preset, isStart: isStart),
    );
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
