import 'dart:typed_data';

import 'package:localsend_app/config/refena.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/known_device.dart';
import 'package:localsend_app/util/native/android_share_shortcuts.dart';
import 'package:localsend_app/util/native/completion_sound_helper.dart';
import 'package:localsend_app/util/native/headless_send_helper.dart';
import 'package:localsend_app/util/native/windows_device_cache.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

class _TestCounterNotifier extends ReduxNotifier<int> {
  @override
  int init() => 0;
}

class _IncrementAction extends ReduxAction<_TestCounterNotifier, int> {
  @override
  int reduce() => state + 1;
}

void main() {
  group('parseSendToArgs', () {
    test('parses fingerprint and multiple paths with --hidden', () {
      final parsed = parseSendToArgs([
        '--hidden',
        '--send-to',
        'FP1234',
        r'C:\Users\Example\Desktop\a.png',
        r'C:\Users\Example\Desktop\folder',
      ]);

      expect(parsed, isNotNull);
      expect(parsed!.fingerprint, 'FP1234');
      expect(parsed.paths, [
        r'C:\Users\Example\Desktop\a.png',
        r'C:\Users\Example\Desktop\folder',
      ]);
    });

    test('returns null when --send-to is missing, empty, or has no paths', () {
      expect(parseSendToArgs([r'C:\a.txt']), isNull);
      expect(parseSendToArgs(['--send-to', '', r'C:\a.txt']), isNull);
      expect(parseSendToArgs(['--send-to', 'FP1234']), isNull);
      expect(parseSendToArgs(['--send-to', 'FP1234', '--hidden']), isNull);
    });

    test('skips --share and --text arguments safely', () {
      final parsed = parseSendToArgs([
        '--text',
        'hello',
        '--send-to',
        'FP99',
        r'D:\pic.jpg',
      ]);

      expect(parsed, isNotNull);
      expect(parsed!.fingerprint, 'FP99');
      expect(parsed.paths, [r'D:\pic.jpg']);
    });
  });

  group('buildDeviceCachePayload', () {
    test('deduplicates by fingerprint, honors customAlias, and sorts online+favorite first', () {
      final favorites = [
        const FavoriteDevice(
          id: '1',
          fingerprint: 'FP_OFFLINE_FAV',
          ip: '192.168.1.50',
          port: 53317,
          alias: 'Old Phone',
          customAlias: true,
        ),
        const FavoriteDevice(
          id: '2',
          fingerprint: 'FP_ONLINE_FAV_CUSTOM',
          ip: '192.168.1.10',
          port: 53317,
          alias: 'My Honor',
          customAlias: true,
        ),
        const FavoriteDevice(
          id: '3',
          fingerprint: 'FP_ONLINE_FAV_AUTO',
          ip: '192.168.1.11',
          port: 53317,
          alias: 'Stale Name',
          customAlias: false,
        ),
      ];

      final nearby = <String, Device>{
        'FP_ONLINE_OTHER': const Device(
          signalingId: null,
          ip: '192.168.1.20',
          version: '2.2',
          port: 53317,
          https: true,
          fingerprint: 'FP_ONLINE_OTHER',
          alias: 'Beta Tablet',
          deviceModel: 'Tab',
          deviceType: DeviceType.mobile,
          download: false,
          channels: [],
        ),
        'FP_ONLINE_FAV_CUSTOM': const Device(
          signalingId: null,
          ip: '192.168.43.8',
          version: '2.2',
          port: 53317,
          https: true,
          fingerprint: 'FP_ONLINE_FAV_CUSTOM',
          alias: 'VNE-LX2',
          deviceModel: 'VNE-LX2',
          deviceType: DeviceType.mobile,
          download: false,
          channels: [],
        ),
        'FP_ONLINE_FAV_AUTO': const Device(
          signalingId: null,
          ip: '192.168.1.11',
          version: '2.2',
          port: 53317,
          https: true,
          fingerprint: 'FP_ONLINE_FAV_AUTO',
          alias: 'Alpha Phone',
          deviceModel: 'Phone',
          deviceType: DeviceType.mobile,
          download: false,
          channels: [],
        ),
      };

      final payload = buildDeviceCachePayload(
        exePath: r'E:\landrop.exe',
        favorites: favorites,
        nearbyDevices: nearby,
      );

      expect(payload['exePath'], r'E:\landrop.exe');
      final devices = (payload['devices'] as List).cast<Map<String, dynamic>>();
      expect(devices.map((d) => d['fingerprint']).toList(), [
        'FP_ONLINE_FAV_AUTO',
        'FP_ONLINE_FAV_CUSTOM',
        'FP_ONLINE_OTHER',
        'FP_OFFLINE_FAV',
      ]);
      expect(devices[0]['alias'], 'Alpha Phone');
      expect(devices[1]['alias'], 'My Honor');
      expect(devices[1]['ip'], '192.168.43.8');
      expect(devices[3]['online'], false);
      expect(devices[3]['favorite'], true);
    });
  });

  group('transfer sounds', () {
    test('resolveTransferSoundAsset maps defaults and presets cleanly', () {
      expect(resolveTransferSoundAsset(preset: 'default'), 'assets/sound/marimba_lite.wav');
      expect(resolveTransferSoundAsset(preset: 'classic'), 'assets/sound/default.wav');
      expect(resolveTransferSoundAsset(preset: 'pop'), 'assets/sound/pop.wav');
      expect(resolveTransferSoundAsset(preset: 'blip'), 'assets/sound/blip_done.wav');
      expect(resolveTransferSoundAsset(preset: 'chime'), 'assets/sound/chime_done.wav');
      expect(resolveTransferSoundAsset(preset: 'ding'), 'assets/sound/ding_done.wav');
      expect(resolveTransferSoundAsset(preset: 'unknown'), 'assets/sound/marimba_lite.wav');
    });

    test('transferSoundPresetLabel returns readable labels', () {
      expect(
        transferSoundPresets.map(transferSoundPresetLabel).toList(),
        ['Default', 'Classic', 'Pop', 'Blip', 'Chime', 'Ding', 'Custom file'],
      );
    });

    test('estimateWavDurationSeconds computes WAV length and ignores non-WAV bytes', () {
      Uint8List buildWav({required int byteRate, required int dataSize}) {
        final bytes = Uint8List(44);
        final bd = ByteData.sublistView(bytes);
        bytes.setAll(0, 'RIFF'.codeUnits);
        bd.setUint32(4, 36 + dataSize, Endian.little);
        bytes.setAll(8, 'WAVE'.codeUnits);
        bytes.setAll(12, 'fmt '.codeUnits);
        bd.setUint32(16, 16, Endian.little);
        bd.setUint16(20, 1, Endian.little); // PCM
        bd.setUint16(22, 2, Endian.little); // stereo
        bd.setUint32(24, 44100, Endian.little);
        bd.setUint32(28, byteRate, Endian.little);
        bd.setUint16(32, 4, Endian.little);
        bd.setUint16(34, 16, Endian.little);
        bytes.setAll(36, 'data'.codeUnits);
        bd.setUint32(40, dataSize, Endian.little);
        return bytes;
      }

      // 44100 Hz stereo 16-bit = 176400 B/s; 2.5s = 441000 bytes
      expect(estimateWavDurationSeconds(buildWav(byteRate: 176400, dataSize: 441000)), closeTo(2.5, 0.001));
      // 6.0s > 5s cap
      expect(estimateWavDurationSeconds(buildWav(byteRate: 176400, dataSize: 1058400)), closeTo(6.0, 0.001));
      expect(estimateWavDurationSeconds(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });
  });

  group('buildAndroidShareShortcutsPayload', () {
    test('ranks online favorites first, deduplicates, and caps at maxCount', () {
      final favorites = [
        const FavoriteDevice(
          id: '1',
          fingerprint: 'FP_FAV_OFFLINE',
          ip: '192.168.1.50',
          port: 53317,
          alias: 'Work PC',
          customAlias: true,
        ),
        const FavoriteDevice(
          id: '2',
          fingerprint: 'FP_FAV_ONLINE',
          ip: '192.168.1.10',
          port: 53317,
          alias: 'JAKE PC',
          customAlias: true,
        ),
      ];
      final nearby = <String, Device>{
        'FP_FAV_ONLINE': const Device(
          signalingId: null,
          ip: '192.168.1.10',
          version: '2.2',
          port: 53317,
          https: true,
          fingerprint: 'FP_FAV_ONLINE',
          alias: 'DESKTOP',
          deviceModel: 'Windows',
          deviceType: DeviceType.desktop,
          download: false,
          channels: [],
        ),
        'FP_ONLINE_OTHER': const Device(
          signalingId: null,
          ip: '192.168.1.20',
          version: '2.2',
          port: 53317,
          https: true,
          fingerprint: 'FP_ONLINE_OTHER',
          alias: 'Laptop',
          deviceModel: 'Laptop',
          deviceType: DeviceType.desktop,
          download: false,
          channels: [],
        ),
      };
      final knownDevices = [
        const KnownDevice(
          fingerprint: 'FP_KNOWN_1',
          alias: 'Alpha Tablet',
          ip: '192.168.1.60',
          port: 53317,
          https: true,
          deviceType: DeviceType.mobile,
          lastSeenMs: 1700000000000,
        ),
        const KnownDevice(
          fingerprint: 'FP_KNOWN_2',
          alias: 'Beta Phone',
          ip: '192.168.1.61',
          port: 53317,
          https: true,
          deviceType: DeviceType.mobile,
          lastSeenMs: 1700000000000,
        ),
      ];

      final payload = buildAndroidShareShortcutsPayload(
        favorites: favorites,
        nearbyDevices: nearby,
        knownDevices: knownDevices,
        maxCount: 4,
      );

      expect(payload.map((e) => e['fingerprint']).toList(), [
        'FP_FAV_ONLINE',
        'FP_ONLINE_OTHER',
        'FP_FAV_OFFLINE',
        'FP_KNOWN_1',
      ]);
      expect(payload.first['alias'], 'JAKE PC');
      expect(payload.first['deviceType'], 'desktop');
    });
  });

  group('KnownDevice & device cache', () {
    test('KnownDevice round-trips JSON cleanly', () {
      const known = KnownDevice(
        fingerprint: 'FP_KNOWN_1',
        alias: 'JAKE Phone',
        ip: '192.168.43.12',
        port: 53317,
        https: true,
        deviceType: DeviceType.mobile,
        lastSeenMs: 1700000000000,
      );

      final decoded = KnownDevice.fromJson(known.toJson());
      expect(decoded.fingerprint, 'FP_KNOWN_1');
      expect(decoded.alias, 'JAKE Phone');
      expect(decoded.ip, '192.168.43.12');
      expect(decoded.port, 53317);
      expect(decoded.https, true);
      expect(decoded.deviceType, DeviceType.mobile);
      expect(decoded.lastSeenMs, 1700000000000);
    });

    test('buildDeviceCachePayload ranks knownDevices after online devices and offline favorites', () {
      final favorites = [
        const FavoriteDevice(
          id: '1',
          fingerprint: 'FP_OFFLINE_FAV',
          ip: '192.168.1.50',
          port: 53317,
          alias: 'Saved Fav',
          customAlias: true,
        ),
      ];
      final nearby = <String, Device>{
        'FP_ONLINE': const Device(
          signalingId: null,
          ip: '192.168.1.20',
          version: '2.2',
          port: 53317,
          https: true,
          fingerprint: 'FP_ONLINE',
          alias: 'Online Device',
          deviceModel: 'PC',
          deviceType: DeviceType.desktop,
          download: false,
          channels: [],
        ),
      };
      final knownDevices = [
        const KnownDevice(
          fingerprint: 'FP_OFFLINE_KNOWN',
          alias: 'Remembered Phone',
          ip: '192.168.1.77',
          port: 53317,
          https: true,
          deviceType: DeviceType.mobile,
          lastSeenMs: 1700000000000,
        ),
      ];

      final payload = buildDeviceCachePayload(
        exePath: r'E:\landrop.exe',
        favorites: favorites,
        nearbyDevices: nearby,
        knownDevices: knownDevices,
      );

      final devices = (payload['devices'] as List).cast<Map<String, dynamic>>();
      expect(devices.map((d) => d['fingerprint']).toList(), [
        'FP_ONLINE',
        'FP_OFFLINE_FAV',
        'FP_OFFLINE_KNOWN',
      ]);
      expect(devices[2]['alias'], 'Remembered Phone');
      expect(devices[2]['online'], false);
      expect(devices[2]['favorite'], false);
    });
  });

  group('ReleaseNoopRefenaObserver', () {
    test('keeps ReduxProvider onChanged active when used in RefenaContainer', () {
      int? observedPrev;
      int? observedNext;
      final testProvider = ReduxProvider<_TestCounterNotifier, int>(
        (ref) => _TestCounterNotifier(),
        onChanged: (prev, next, ref) {
          observedPrev = prev;
          observedNext = next;
        },
      );

      final container = RefenaContainer(
        observers: [ReleaseNoopRefenaObserver()],
      );
      addTearDown(() => container.dispose(testProvider));

      container.redux(testProvider).dispatch(_IncrementAction());
      expect(observedPrev, 0);
      expect(observedNext, 1);
    });
  });
}
