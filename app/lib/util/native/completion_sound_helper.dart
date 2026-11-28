import 'dart:convert' show ascii;
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
const transferSoundPresets = ['default', 'classic', 'pop', 'blip', 'chime', 'ding', 'custom'];
const maxCustomSoundBytes = 2 * 1024 * 1024; // 2 MB
const maxCustomSoundDurationSeconds = 5.0;

final Map<String, String> _cachedAssetPaths = {};
int _soundEpoch = 0;

void cancelPendingFinishSound() {
  _soundEpoch++;
}

String transferSoundPresetLabel(String preset) {
  switch (preset) {
    case 'default':
      return 'Default';
    case 'classic':
      return 'Classic';
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
  bool isStart = false,
}) {
  switch (preset) {
    case 'classic':
      return 'assets/sound/default.wav';
    case 'pop':
      return 'assets/sound/pop.wav';
    case 'blip':
      return 'assets/sound/blip_done.wav';
    case 'chime':
      return 'assets/sound/chime_done.wav';
    case 'ding':
      return 'assets/sound/ding_done.wav';
    case 'default':
    default:
      return 'assets/sound/marimba_lite.wav';
  }
}

/// Returns the duration in seconds for a PCM/RIFF `.wav` byte buffer, or `null` if unknown.
double? estimateWavDurationSeconds(Uint8List bytes) {
  if (bytes.length < 44) {
    return null;
  }
  if (ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' || ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WAVE') {
    return null;
  }

  final data = ByteData.sublistView(bytes);
  int offset = 12;
  int? byteRate;
  int? dataSize;

  while (offset + 8 <= bytes.length) {
    final chunkId = ascii.decode(bytes.sublist(offset, offset + 4), allowInvalid: true);
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    final payloadOffset = offset + 8;

    if (chunkId == 'fmt ' && chunkSize >= 16 && payloadOffset + 12 <= bytes.length) {
      byteRate = data.getUint32(payloadOffset + 8, Endian.little);
    } else if (chunkId == 'data') {
      dataSize = chunkSize;
      if (byteRate != null && byteRate > 0) {
        return dataSize / byteRate;
      }
    }

    final step = 8 + chunkSize + (chunkSize.isOdd ? 1 : 0);
    if (step <= 8) {
      break;
    }
    offset += step;
  }

  if (byteRate != null && byteRate > 0 && dataSize != null) {
    return dataSize / byteRate;
  }
  return null;
}

Future<void> playTransferFinishSound({
  required String preset,
  String? customPath,
  bool respectStartGap = true,
}) async {
  final epoch = _soundEpoch;
  if (epoch != _soundEpoch) {
    return;
  }
  await _playConfiguredSound(
    preset: preset,
    customPath: customPath,
  );
}

/// Extracts the bundled sound lazily and plays it natively without extra packages.
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
  if (bytes.length > maxCustomSoundBytes) {
    throw const FormatException('Custom sound must be 2 MB or smaller');
  }

  final rawExt = p.extension(picked.name).replaceFirst('.', '').toLowerCase();
  final ext = rawExt.isEmpty ? 'wav' : rawExt;
  if (ext == 'wav') {
    final duration = estimateWavDurationSeconds(bytes);
    if (duration != null && duration > maxCustomSoundDurationSeconds) {
      throw const FormatException('Custom sound must be 5 seconds or shorter');
    }
  }

  final dir = await path_provider.getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final destFile = File(p.join(dir.path, 'landrop_custom_sound.$ext'));
  await destFile.writeAsBytes(bytes, flush: true);
  return destFile.path;
}

Future<void> _playConfiguredSound({
  required String preset,
  required String? customPath,
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
      resolveTransferSoundAsset(preset: preset),
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
