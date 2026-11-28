import 'dart:io';

import 'package:collection/collection.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/known_devices_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/pending_send_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/util/send_ignore.dart';
import 'package:localsend_isolates/constants.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/rust/api/metadata.dart';
import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('HeadlessSend');

class SendToRequest {
  final String fingerprint;
  final List<String> paths;

  const SendToRequest({
    required this.fingerprint,
    required this.paths,
  });
}

SendToRequest? parseSendToArgs(List<String> args) {
  String? fingerprint;
  final paths = <String>[];

  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--send-to') {
      if (i + 1 < args.length) {
        fingerprint = args[++i].trim();
      }
      continue;
    }
    if (arg == '--hidden') {
      continue;
    }
    if (arg == '--share' || arg == '--text' || arg == '-t') {
      if (i + 1 < args.length) {
        i++;
      }
      continue;
    }
    if (arg.startsWith('-')) {
      continue;
    }
    if (arg.isNotEmpty) {
      paths.add(arg);
    }
  }

  if (fingerprint == null || fingerprint.isEmpty || paths.isEmpty) {
    return null;
  }

  return SendToRequest(
    fingerprint: fingerprint,
    paths: paths,
  );
}

Future<List<CrossFile>> loadPathsAsCrossFiles(List<String> paths) async {
  final files = <CrossFile>[];

  for (final path in paths) {
    final file = File(path);
    if (file.existsSync()) {
      final crossFile = await CrossFileConverters.convertFile(file);
      if (!files.any((existing) => existing.isSameFile(otherFile: crossFile))) {
        files.add(crossFile);
      }
      continue;
    }

    final directory = Directory(path);
    if (!directory.existsSync()) {
      continue;
    }

    final directoryName = p.basename(path);
    final sendIgnore = SendIgnore();
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }

      final innerRelative = p.relative(entity.path, from: path).replaceAll('\\', '/');
      final relative = '$directoryName/$innerRelative';
      if (sendIgnore.isIgnoreFile(p.basename(entity.path))) {
        sendIgnore.loadIgnoreContent(
          parentPath: innerRelative.contains('/') ? p.dirname(innerRelative) : null,
          ignoreContents: await entity.readAsLines(),
        );
        continue;
      }
      if (sendIgnore.isIgnored(innerRelative)) {
        continue;
      }

      final metadata = await readFileMetadata(path: entity.path);
      final crossFile = CrossFile(
        name: relative,
        fileType: relative.guessFileType(),
        size: entity.lengthSync(),
        thumbnail: null,
        asset: null,
        path: entity.path,
        bytes: null,
        lastModified: metadata?.modified,
        lastAccessed: metadata?.accessed,
      );
      if (!files.any((existing) => existing.isSameFile(otherFile: crossFile))) {
        files.add(crossFile);
      }
    }
  }

  return files;
}

Future<Device?> resolveTargetDeviceByFingerprint(Ref ref, String fingerprint) async {
  final settings = ref.read(settingsProvider);

  Device? target = ref.read(nearbyDevicesProvider).devices[fingerprint];
  if (target == null) {
    ref.redux(nearbyDevicesProvider).dispatch(StartMulticastScan());
    for (int i = 0; i < 17; i++) {
      await Future.delayed(const Duration(milliseconds: 150));
      target = ref.read(nearbyDevicesProvider).devices[fingerprint];
      if (target != null) {
        break;
      }
    }
  }

  if (target == null) {
    final fav = ref.read(favoritesProvider).firstWhereOrNull((e) => e.fingerprint == fingerprint);
    if (fav != null) {
      target = Device(
        signalingId: null,
        ip: fav.ip,
        version: protocolVersion,
        port: fav.port,
        https: settings.https,
        fingerprint: fav.fingerprint,
        alias: fav.alias,
        deviceModel: null,
        deviceType: DeviceType.mobile,
        download: false,
        channels: [
          HttpChannel(host: fav.ip, port: fav.port, https: settings.https),
        ],
      );
    } else {
      target = ref.read(knownDevicesProvider).firstWhereOrNull((e) => e.fingerprint == fingerprint)?.toDevice();
    }
  }

  return target;
}

Future<void> executeHeadlessSend(Ref ref, SendToRequest request) async {
  final files = await loadPathsAsCrossFiles(request.paths);
  if (files.isEmpty) {
    _logger.warning('No readable files found for --send-to ${request.fingerprint}');
    return;
  }

  final settings = ref.read(settingsProvider);
  if (!settings.silentCompletion && checkPlatformHasTray()) {
    await showFromTray();
  }

  final target = await resolveTargetDeviceByFingerprint(ref, request.fingerprint);
  if (target == null) {
    _logger.warning('Target device ${request.fingerprint} is unreachable on the local network');
    if (checkPlatformHasTray()) {
      await showFromTray();
    }
    return;
  }

  await ref
      .notifier(pendingSendProvider)
      .enqueue(
        target: target,
        files: files,
        background: settings.silentCompletion,
      );
}
