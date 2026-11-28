import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

part 'android_channel.mapper.dart';

const _methodChannel = MethodChannel('org.localsend.localsend_app/localsend');
final _logger = Logger('AndroidSaf');

/// From Android 10 and above, we need to use the Storage Access Framework (SAF) to access files due to the scoped storage.
/// SAF itself is available from Android 4.4 (API level 19).
/// We implemented our own algorithm to build encode and decode content URIs.
/// Older versions might also work but the encoded content URI is not guaranteed to work with our algorithm.
const contentUriMinSdk = 27;

Future<PickDirectoryResult?> pickDirectoryAndroid() async {
  final result = await _methodChannel.invokeMethod<Map>('pickDirectory');
  if (result == null) {
    return null;
  }

  return PickDirectoryResultMapper.fromJson({
    'directoryUri': result['directoryUri'],
    'files': (result['files'] as List).map((e) => FileInfoMapper.fromJson((e as Map).cast<String, dynamic>())).toList(),
  });
}

Future<String?> pickDirectoryPathAndroid() async {
  final result = await _methodChannel.invokeMethod<String>('pickDirectoryPath');
  return result;
}

Future<List<FileInfo>?> pickFilesAndroid() async {
  final result = await _methodChannel.invokeMethod<List>('pickFiles');
  if (result == null) {
    return null;
  }

  return result.map((e) => FileInfoMapper.fromJson((e as Map).cast<String, dynamic>())).toList();
}

/// Returns the global "Download" directory, e.g. /storage/emulated/0/Download.
Future<String?> getDownloadsDirectoryAndroid() async {
  try {
    return await _methodChannel.invokeMethod<String>('getDownloadsDirectory');
  } catch (e) {
    _logger.warning('Could not get downloads directory', e);
    return null;
  }
}

/// Returns the user-configured Android device name (Settings.Global.DEVICE_NAME / bluetooth_name).
Future<String?> getDeviceNameAndroid() async {
  try {
    return await _methodChannel.invokeMethod<String>('getDeviceName');
  } catch (e) {
    _logger.warning('Could not get Android device name', e);
    return null;
  }
}

Future<bool> getSystemAnimationsStatusAndroid() async {
  return await _methodChannel.invokeMethod('isAnimationsEnabled') ?? true;
}

/// Requests the "Nearby devices" permission gating local network access on Android 17+.
/// Returns true when granted or when running on an older Android version.
Future<bool> requestLocalNetworkPermissionAndroid() async {
  try {
    return await _methodChannel.invokeMethod<bool>('requestLocalNetworkPermission') ?? false;
  } catch (e) {
    _logger.warning('Could not request local network permission', e);
    return false;
  }
}

Future<void> openContentUri({
  required String uri,
}) async {
  _logger.info('Opening content URI: $uri');
  await _methodChannel.invokeMethod('openContentUri', {
    'uri': uri,
  });
}

/// Tells MainActivity that the Dart side is now subscribed to the share_handler media stream,
/// so share intents that were held back during app start can be replayed.
Future<void> flushPendingShareIntentsAndroid() async {
  try {
    await _methodChannel.invokeMethod('shareIntentReady');
  } catch (e) {
    _logger.warning('Could not flush pending share intents', e);
  }
}

/// Returns and clears the target device fingerprint if launched via an Android Direct Share shortcut.
Future<String?> consumeDirectShareTargetAndroid() async {
  try {
    return await _methodChannel.invokeMethod<String>('consumeDirectShareTarget');
  } catch (e) {
    _logger.warning('Could not read direct share target', e);
    return null;
  }
}

/// Sends the Android activity to the background so the user returns to their previous app.
Future<void> moveTaskToBackAndroid() async {
  try {
    await _methodChannel.invokeMethod('moveTaskToBack');
  } catch (e) {
    _logger.warning('Could not move task to back', e);
  }
}

/// Publishes dynamic Direct Share shortcuts for known/online devices on Android.
Future<void> updateShareShortcutsAndroid(List<Map<String, dynamic>> devices) async {
  try {
    await _methodChannel.invokeMethod('updateShareShortcuts', {
      'devices': devices,
    });
  } catch (e) {
    _logger.warning('Could not update Android share shortcuts', e);
  }
}

Future<void> openGallery() async {
  _logger.info('Opening gallery');
  await _methodChannel.invokeMethod('openGallery');
}

Future<void> playCompletionSoundAndroid(String path) async {
  await _methodChannel.invokeMethod('playCompletionSound', {
    'path': path,
  });
}

Future<void> showIncomingRequestNotificationAndroid({
  required String senderAlias,
  required int fileCount,
}) async {
  try {
    await _methodChannel.invokeMethod('showIncomingRequestNotification', {
      'senderAlias': senderAlias,
      'fileCount': fileCount,
    });
  } catch (e) {
    _logger.warning('Could not show incoming request notification', e);
  }
}

Future<void> cancelIncomingRequestNotificationAndroid() async {
  try {
    await _methodChannel.invokeMethod('cancelIncomingRequestNotification');
  } catch (e) {
    _logger.warning('Could not cancel incoming request notification', e);
  }
}

Future<void> showTransferProgressNotificationAndroid({
  required String title,
  required String body,
  required int progress,
  int max = 100,
  bool indeterminate = false,
}) async {
  try {
    await _methodChannel.invokeMethod('showTransferProgressNotification', {
      'title': title,
      'body': body,
      'progress': progress,
      'max': max,
      'indeterminate': indeterminate,
    });
  } catch (e) {
    _logger.warning('Could not show transfer progress notification', e);
  }
}

Future<void> showTransferCompletedNotificationAndroid({
  required String title,
  required String body,
}) async {
  try {
    await _methodChannel.invokeMethod('showTransferCompletedNotification', {
      'title': title,
      'body': body,
    });
  } catch (e) {
    _logger.warning('Could not show transfer completed notification', e);
  }
}

Future<void> cancelTransferProgressNotificationAndroid() async {
  try {
    await _methodChannel.invokeMethod('cancelTransferProgressNotification');
  } catch (e) {
    _logger.warning('Could not cancel transfer progress notification', e);
  }
}

void registerAndroidCancelTransferHandler(void Function() onCancel) {
  _methodChannel.setMethodCallHandler((call) async {
    if (call.method == 'cancelActiveTransfer') {
      onCancel();
    }
  });
}

@MappableClass()
class PickDirectoryResult with PickDirectoryResultMappable {
  final String directoryUri;
  final List<FileInfo> files;

  PickDirectoryResult({
    required this.directoryUri,
    required this.files,
  });
}

@MappableClass()
class FileInfo with FileInfoMappable {
  final String name;
  final int size;
  final String uri;

  /// RFC 3339 in UTC. Null when the document provider does not know it.
  final String? lastModified;

  FileInfo({
    required this.name,
    required this.size,
    required this.uri,
    required this.lastModified,
  });
}
