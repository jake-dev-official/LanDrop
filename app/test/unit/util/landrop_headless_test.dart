import 'package:localsend_app/config/refena.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/known_device.dart';
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
    test('resolveTransferSoundAsset maps start and done sounds for all presets', () {
      expect(resolveTransferSoundAsset(preset: 'default', isStart: true), 'assets/sound/pop_start.wav');
      expect(resolveTransferSoundAsset(preset: 'default', isStart: false), 'assets/sound/default.wav');
      expect(resolveTransferSoundAsset(preset: 'pop', isStart: true), 'assets/sound/pop_start.wav');
      expect(resolveTransferSoundAsset(preset: 'pop', isStart: false), 'assets/sound/pop.wav');
      expect(resolveTransferSoundAsset(preset: 'blip', isStart: true), 'assets/sound/blip_start.wav');
      expect(resolveTransferSoundAsset(preset: 'blip', isStart: false), 'assets/sound/blip_done.wav');
      expect(resolveTransferSoundAsset(preset: 'chime', isStart: true), 'assets/sound/chime_start.wav');
      expect(resolveTransferSoundAsset(preset: 'chime', isStart: false), 'assets/sound/chime_done.wav');
      expect(resolveTransferSoundAsset(preset: 'ding', isStart: true), 'assets/sound/ding_start.wav');
      expect(resolveTransferSoundAsset(preset: 'ding', isStart: false), 'assets/sound/ding_done.wav');
      expect(resolveTransferSoundAsset(preset: 'unknown', isStart: true), 'assets/sound/pop_start.wav');
      expect(resolveTransferSoundAsset(preset: 'unknown', isStart: false), 'assets/sound/default.wav');
    });

    test('transferSoundPresetLabel returns readable labels', () {
      expect(
        transferSoundPresets.map(transferSoundPresetLabel).toList(),
        ['Default', 'Pop', 'Blip', 'Chime', 'Ding', 'Custom file'],
      );
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
