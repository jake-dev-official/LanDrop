import 'dart:async';

import 'package:collection/collection.dart';
import 'package:file_selector/file_selector.dart' show openFiles;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/known_device.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/pages/receive_history_page.dart';
import 'package:localsend_app/pages/tabs/send_tab_vm.dart';
import 'package:localsend_app/pages/tabs/settings_tab.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/known_devices_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/pending_send_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/headless_send_helper.dart';
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/dialogs/address_input_dialog.dart';
import 'package:localsend_isolates/constants.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

final _logger = Logger('LanDropHomeView');

class LanDropHomeView extends StatefulWidget {
  const LanDropHomeView({super.key});

  @override
  State<LanDropHomeView> createState() => _LanDropHomeViewState();
}

class _LanDropHomeViewState extends State<LanDropHomeView> with Refena {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedFingerprint;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    ensureRef((ref) async {
      await ref.global.dispatchAsync(SendTabInitAction(context));
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    if (_scanning) {
      return;
    }
    setState(() => _scanning = true);
    try {
      await ref.redux(localIpProvider).dispatchAsync(FetchLocalIpAction());
      ref.redux(nearbyDevicesProvider).dispatch(ClearFoundDevicesAction());
      await ref.global.dispatchAsync(StartSmartScan());
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      }
    }
  }

  Future<void> _openSettings() async {
    await context.push(() => const _LanDropSettingsPage());
  }

  Future<void> _openHistory() async {
    await context.push(() => const ReceiveHistoryPage());
  }

  Future<void> _toggleFavorite(_UnifiedDevice entry) async {
    final fp = entry.fingerprint;
    if (entry.isFavorite) {
      await ref.redux(favoritesProvider).dispatchAsync(RemoveFavoriteAction(deviceFingerprint: fp));
      if (mounted) {
        context.showSnackBar('Removed ${entry.displayName} from favorites');
      }
      return;
    }
    final ip = entry.device.ip;
    if (ip == null || ip.isEmpty) {
      return;
    }
    await ref
        .redux(favoritesProvider)
        .dispatchAsync(
          AddFavoriteAction(
            FavoriteDevice.fromValues(
              fingerprint: fp,
              ip: ip,
              port: entry.device.port,
              alias: entry.displayName,
            ),
          ),
        );
    if (mounted) {
      context.showSnackBar('Added ${entry.displayName} to favorites');
    }
  }

  Future<void> _removeDevice(_UnifiedDevice entry) async {
    final fp = entry.fingerprint;
    await ref.redux(knownDevicesProvider).dispatchAsync(RemoveKnownDeviceAction(fp));
    if (entry.isFavorite) {
      await ref.redux(favoritesProvider).dispatchAsync(RemoveFavoriteAction(deviceFingerprint: fp));
    }
    ref.redux(nearbyDevicesProvider).dispatch(RemoveFoundDeviceAction(fp));
    if (mounted) {
      if (_selectedFingerprint == fp) {
        setState(() {
          _selectedFingerprint = null;
        });
      }
      context.showSnackBar('Removed ${entry.displayName}');
    }
  }

  Future<void> _showDesktopDeviceMenu(BuildContext context, _UnifiedDevice entry, Offset globalPosition) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) {
      return;
    }
    final colorScheme = Theme.of(context).colorScheme;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'favorite',
          child: Row(
            children: [
              Icon(
                entry.isFavorite ? Icons.star : Icons.star_border,
                size: 18,
                color: entry.isFavorite ? Colors.amber : null,
              ),
              const SizedBox(width: 10),
              Text(entry.isFavorite ? 'Remove from favorites' : 'Add to favorites'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'remove',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: colorScheme.error),
              const SizedBox(width: 10),
              Text('Remove device', style: TextStyle(color: colorScheme.error)),
            ],
          ),
        ),
      ],
    );
    if (!mounted || choice == null) {
      return;
    }
    if (choice == 'favorite') {
      await _toggleFavorite(entry);
    } else if (choice == 'remove') {
      await _removeDevice(entry);
    }
  }

  Future<void> _showMobileDeviceSheet(BuildContext context, _UnifiedDevice entry) async {
    final colorScheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    entry.displayName,
                    style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  entry.isFavorite ? Icons.star : Icons.star_border,
                  color: entry.isFavorite ? Colors.amber : null,
                ),
                title: Text(entry.isFavorite ? 'Remove from favorites' : 'Add to favorites'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_toggleFavorite(entry));
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: colorScheme.error),
                title: Text('Remove device', style: TextStyle(color: colorScheme.error)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_removeDevice(entry));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openAddressDialogAndSelect({required bool sendImmediatelyIfSelected}) async {
    final device = await showDialog<Device?>(
      context: context,
      builder: (_) => const AddressInputDialog(),
    );
    if (device == null || !mounted) {
      return;
    }
    setState(() {
      _selectedFingerprint = device.fingerprint;
    });
    if (sendImmediatelyIfSelected) {
      await _sendToDeviceStraight(device);
    }
  }

  Future<void> _dispatchSend(Device target, List<CrossFile> files) async {
    final busy = ref.read(sendProvider).values.any((s) => s.status == SessionStatus.sending || s.status == SessionStatus.waiting);
    final queued = await ref.notifier(pendingSendProvider).enqueue(target: target, files: files);
    if (queued && mounted) {
      context.showSnackBar(
        busy
            ? 'Queued for ${target.alias} — will send after current transfer finishes'
            : 'Queued for ${target.alias} — will send automatically when it connects (5 min)',
      );
    }
  }

  Future<void> _sendToDeviceStraight(Device target) async {
    final queued = ref.read(selectedSendingFilesProvider);
    if (queued.isNotEmpty) {
      final files = List<CrossFile>.of(queued);
      ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction());
      await _dispatchSend(target, files);
      return;
    }

    final files = await _pickFilesDirectly();
    if (files.isEmpty || !mounted) {
      return;
    }
    await _dispatchSend(target, files);
  }

  Future<void> _sendFolderToDevice(Device target) async {
    final dirPath = await pickDirectoryPath();
    if (dirPath == null || dirPath.isEmpty || !mounted) {
      return;
    }
    final files = await loadPathsAsCrossFiles([dirPath]);
    if (files.isEmpty || !mounted) {
      return;
    }
    await _dispatchSend(target, files);
  }

  Future<List<CrossFile>> _pickFilesDirectly() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final result = await android_channel.pickFilesAndroid();
        if (result == null || result.isEmpty) {
          return const [];
        }
        return [
          for (final info in result) await CrossFileConverters.convertFileInfo(info),
        ];
      }
      final xFiles = await openFiles();
      if (xFiles.isEmpty) {
        return const [];
      }
      return [
        for (final xf in xFiles) await CrossFileConverters.convertXFile(xf),
      ];
    } on PlatformException catch (e) {
      if (e.code != 'CANCELED') {
        _logger.warning('File picker failed', e);
      }
      return const [];
    } catch (e) {
      _logger.warning('File picker failed', e);
      return const [];
    }
  }

  List<_UnifiedDevice> _buildUnifiedDevices({
    required List<FavoriteDevice> favorites,
    required Map<String, Device> nearby,
    required List<KnownDevice> knownDevices,
    required bool https,
  }) {
    final favByFp = {for (final f in favorites) f.fingerprint: f};
    final knownByFp = {for (final k in knownDevices) k.fingerprint: k};
    final allFps = <String>{...favByFp.keys, ...nearby.keys, ...knownByFp.keys};
    final list = <_UnifiedDevice>[];

    for (final fp in allFps) {
      final fav = favByFp[fp];
      final online = nearby[fp];
      final known = knownByFp[fp];
      if (fav == null && online == null && known == null) {
        continue;
      }
      final isOnline = online != null && (online.ip?.isNotEmpty ?? false);
      final displayName = fav != null ? (fav.customAlias || online == null ? fav.alias : online.alias) : (online?.alias ?? known!.alias);
      final device =
          online ??
          known?.toDevice() ??
          Device(
            signalingId: null,
            ip: fav!.ip,
            version: protocolVersion,
            port: fav.port,
            https: https,
            fingerprint: fav.fingerprint,
            alias: fav.alias,
            deviceModel: null,
            deviceType: DeviceType.mobile,
            download: false,
            channels: [
              HttpChannel(host: fav.ip, port: fav.port, https: https),
            ],
          );
      list.add(
        _UnifiedDevice(
          fingerprint: fp,
          displayName: displayName,
          device: device,
          isOnline: isOnline,
          isFavorite: fav != null,
        ),
      );
    }

    list.sort((a, b) {
      final rankA = _deviceRank(a);
      final rankB = _deviceRank(b);
      if (rankA != rankB) {
        return rankA.compareTo(rankB);
      }
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });

    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) {
      return list;
    }
    return list.where((d) {
      return d.displayName.toLowerCase().contains(q) || (d.device.ip?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  int _deviceRank(_UnifiedDevice d) {
    if (d.isOnline && d.isFavorite) return 0;
    if (d.isOnline) return 1;
    if (d.isFavorite) return 2;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch(settingsProvider);
    final serverState = context.watch(serverProvider);
    final favorites = context.watch(favoritesProvider);
    final knownDevices = context.watch(knownDevicesProvider);
    final nearbyDevices = context.watch(nearbyDevicesProvider).allDevices;
    final selectedFiles = context.watch(selectedSendingFilesProvider);
    final sendSessions = context.watch(sendProvider);
    final pendingSends = context.watch(pendingSendProvider);
    final receiveSession = serverState?.session;
    final history = context.watch(receiveHistoryProvider);

    final devices = _buildUnifiedDevices(
      favorites: favorites,
      nearby: nearbyDevices,
      knownDevices: knownDevices,
      https: settings.https,
    );

    final selectedDevice = _selectedFingerprint == null ? null : devices.firstWhereOrNull((d) => d.fingerprint == _selectedFingerprint);

    final ownAlias = serverState?.alias ?? settings.alias;
    final isReady = serverState != null;
    final width = MediaQuery.sizeOf(context).width;
    final isDesktopSplit = width >= 720;

    if (!isDesktopSplit) {
      return _MobileView(
        ownAlias: ownAlias,
        isReady: isReady,
        scanning: _scanning,
        devices: devices,
        selectedFiles: selectedFiles,
        receiveSession: receiveSession,
        sendSessions: sendSessions,
        pendingSends: pendingSends,
        onRefresh: _refreshDevices,
        onOpenHistory: _openHistory,
        onOpenSettings: _openSettings,
        onClearSelectedFiles: () => ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction()),
        onTapDevice: (entry) => _sendToDeviceStraight(entry.device),
        onToggleFavorite: _toggleFavorite,
        onSecondaryTapDevice: (entry, pos) => unawaited(_showDesktopDeviceMenu(context, entry, pos)),
        onLongPressDevice: (entry) => _showMobileDeviceSheet(context, entry),
        onTapManualIp: () => _openAddressDialogAndSelect(sendImmediatelyIfSelected: true),
        onCancelReceive: () => ref.notifier(serverProvider).cancelSession(),
        onCancelSend: (sessionId) => ref.notifier(sendProvider).cancelSession(sessionId),
        onCancelPending: (id) => ref.notifier(pendingSendProvider).cancel(id),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 300,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            border: Border(right: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.4))),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 10, 10),
                child: Row(
                  children: [
                    Text(
                      t.appName,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: t.sendTab.scan,
                      onPressed: _refreshDevices,
                      icon: _scanning
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh, size: 20),
                    ),
                    IconButton(
                      tooltip: t.settingsTab.title,
                      onPressed: _openSettings,
                      icon: const Icon(Icons.settings_outlined, size: 20),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _searchQuery = value),
                  onSubmitted: (_) => _openAddressDialogAndSelect(sendImmediatelyIfSelected: false),
                  decoration: InputDecoration(
                    hintText: 'Search devices',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            icon: const Icon(Icons.close, size: 18),
                          )
                        : IconButton(
                            tooltip: t.sendTab.manualSending,
                            onPressed: () => _openAddressDialogAndSelect(sendImmediatelyIfSelected: false),
                            icon: const Icon(Icons.add_link, size: 18),
                          ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: devices.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.devices, size: 36, color: colorScheme.onSurfaceVariant),
                              const SizedBox(height: 10),
                              Text(
                                'No devices found yet',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 10),
                              TextButton.icon(
                                onPressed: _refreshDevices,
                                icon: const Icon(Icons.refresh, size: 18),
                                label: const Text('Scan again'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        itemCount: devices.length,
                        itemBuilder: (context, index) {
                          final entry = devices[index];
                          final isSelected = selectedDevice?.fingerprint == entry.fingerprint;
                          return _DeviceRowTile(
                            entry: entry,
                            selected: isSelected,
                            onTap: () => setState(() => _selectedFingerprint = entry.fingerprint),
                            onToggleFavorite: () => _toggleFavorite(entry),
                            onSecondaryTap: (pos) => unawaited(_showDesktopDeviceMenu(context, entry, pos)),
                            onLongPress: () => unawaited(_showMobileDeviceSheet(context, entry)),
                          );
                        },
                      ),
              ),
              Divider(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isReady ? Colors.green : colorScheme.outline,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isReady ? 'Ready as $ownAlias' : t.general.offline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                    IconButton(
                      tooltip: t.receiveHistoryPage.title,
                      onPressed: _openHistory,
                      icon: const Icon(Icons.history, size: 19),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _DesktopDetailPane(
            selectedDevice: selectedDevice,
            selectedFiles: selectedFiles,
            receiveSession: receiveSession,
            sendSessions: sendSessions,
            pendingSends: pendingSends,
            history: history,
            onClearSelectedFiles: () => ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction()),
            onSendFiles: () {
              if (selectedDevice != null) {
                unawaited(_sendToDeviceStraight(selectedDevice.device));
              }
            },
            onSendFolder: () {
              if (selectedDevice != null) {
                unawaited(_sendFolderToDevice(selectedDevice.device));
              }
            },
            onOpenHistory: _openHistory,
            onCancelReceive: () => ref.notifier(serverProvider).cancelSession(),
            onCancelSend: (sessionId) => ref.notifier(sendProvider).cancelSession(sessionId),
            onCancelPending: (id) => ref.notifier(pendingSendProvider).cancel(id),
          ),
        ),
      ],
    );
  }
}

class _MobileView extends StatelessWidget {
  final String ownAlias;
  final bool isReady;
  final bool scanning;
  final List<_UnifiedDevice> devices;
  final List<CrossFile> selectedFiles;
  final ReceiveSessionState? receiveSession;
  final Map<String, SendSessionState> sendSessions;
  final List<PendingSendEntry> pendingSends;
  final VoidCallback onRefresh;
  final VoidCallback onOpenHistory;
  final VoidCallback onOpenSettings;
  final VoidCallback onClearSelectedFiles;
  final void Function(_UnifiedDevice entry) onTapDevice;
  final void Function(_UnifiedDevice entry) onToggleFavorite;
  final void Function(_UnifiedDevice entry, Offset globalPosition) onSecondaryTapDevice;
  final void Function(_UnifiedDevice entry) onLongPressDevice;
  final VoidCallback onTapManualIp;
  final VoidCallback onCancelReceive;
  final void Function(String sessionId) onCancelSend;
  final void Function(String id) onCancelPending;

  const _MobileView({
    required this.ownAlias,
    required this.isReady,
    required this.scanning,
    required this.devices,
    required this.selectedFiles,
    required this.receiveSession,
    required this.sendSessions,
    required this.pendingSends,
    required this.onRefresh,
    required this.onOpenHistory,
    required this.onOpenSettings,
    required this.onClearSelectedFiles,
    required this.onTapDevice,
    required this.onToggleFavorite,
    required this.onSecondaryTapDevice,
    required this.onLongPressDevice,
    required this.onTapManualIp,
    required this.onCancelReceive,
    required this.onCancelSend,
    required this.onCancelPending,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeSend = sendSessions.values.firstWhereOrNull((s) => s.status == SessionStatus.sending || s.status == SessionStatus.waiting);
    final activeReceive = receiveSession != null && receiveSession!.status == SessionStatus.sending ? receiveSession : null;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 10, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.appName,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isReady ? Colors.green : colorScheme.outline,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            isReady ? 'Ready as $ownAlias' : t.general.offline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: t.sendTab.scan,
                onPressed: onRefresh,
                icon: scanning ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: t.receiveHistoryPage.title,
                onPressed: onOpenHistory,
                icon: const Icon(Icons.history),
              ),
              IconButton(
                tooltip: t.settingsTab.title,
                onPressed: onOpenSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
        ),
        if (selectedFiles.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Card(
              color: colorScheme.primaryContainer,
              child: ListTile(
                dense: true,
                leading: Icon(Icons.attach_file, color: colorScheme.onPrimaryContainer),
                title: Text(
                  selectedFiles.length == 1
                      ? 'Tap a device to send ${selectedFiles.first.name}'
                      : 'Tap a device to send ${selectedFiles.length} files',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colorScheme.onPrimaryContainer),
                ),
                trailing: IconButton(
                  onPressed: onClearSelectedFiles,
                  icon: Icon(Icons.close, color: colorScheme.onPrimaryContainer),
                ),
              ),
            ),
          ),
        Expanded(
          child: devices.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.devices, size: 48, color: colorScheme.onSurfaceVariant),
                        const SizedBox(height: 12),
                        Text(
                          'No nearby devices yet',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Keep both devices on the same Wi-Fi or hotspot.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 10,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: onRefresh,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Scan'),
                            ),
                            OutlinedButton.icon(
                              onPressed: onTapManualIp,
                              icon: const Icon(Icons.add_link, size: 18),
                              label: const Text('Enter IP'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  itemCount: devices.length + 1,
                  itemBuilder: (context, index) {
                    if (index == devices.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: TextButton.icon(
                          onPressed: onTapManualIp,
                          icon: const Icon(Icons.add_link, size: 18),
                          label: const Text('Send by IP address'),
                        ),
                      );
                    }
                    final entry = devices[index];
                    return _DeviceRowTile(
                      entry: entry,
                      selected: false,
                      onTap: () => onTapDevice(entry),
                      onToggleFavorite: () => onToggleFavorite(entry),
                      onSecondaryTap: (pos) => onSecondaryTapDevice(entry, pos),
                      onLongPress: () => onLongPressDevice(entry),
                    );
                  },
                ),
        ),
        if (activeReceive != null)
          _ActiveTransferBar(
            sessionId: activeReceive.sessionId,
            label: 'Receiving from ${activeReceive.senderAlias}',
            files: {for (final f in activeReceive.files.values) f.file.id: f.file.size},
            skippedFileIds: {
              for (final f in activeReceive.files.values)
                if (f.desiredName == null) f.file.id,
            },
            onCancel: onCancelReceive,
          )
        else if (activeSend != null)
          _ActiveTransferBar(
            sessionId: activeSend.sessionId,
            label: 'Sending to ${activeSend.target.alias}',
            files: {for (final f in activeSend.files.values) f.file.id: f.file.size},
            skippedFileIds: {
              for (final f in activeSend.files.values)
                if (f.token == null) f.file.id,
            },
            onCancel: () => onCancelSend(activeSend.sessionId),
          ),
        for (final pending in pendingSends)
          _PendingSendBar(
            entry: pending,
            onCancel: () => onCancelPending(pending.id),
          ),
      ],
    );
  }
}

class _DesktopDetailPane extends StatelessWidget {
  final _UnifiedDevice? selectedDevice;
  final List<CrossFile> selectedFiles;
  final ReceiveSessionState? receiveSession;
  final Map<String, SendSessionState> sendSessions;
  final List<PendingSendEntry> pendingSends;
  final List<ReceiveHistoryEntry> history;
  final VoidCallback onClearSelectedFiles;
  final VoidCallback onSendFiles;
  final VoidCallback onSendFolder;
  final VoidCallback onOpenHistory;
  final VoidCallback onCancelReceive;
  final void Function(String sessionId) onCancelSend;
  final void Function(String id) onCancelPending;

  const _DesktopDetailPane({
    required this.selectedDevice,
    required this.selectedFiles,
    required this.receiveSession,
    required this.sendSessions,
    required this.pendingSends,
    required this.history,
    required this.onClearSelectedFiles,
    required this.onSendFiles,
    required this.onSendFolder,
    required this.onOpenHistory,
    required this.onCancelReceive,
    required this.onCancelSend,
    required this.onCancelPending,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeSend = sendSessions.values.firstWhereOrNull(
      (s) =>
          (s.status == SessionStatus.sending || s.status == SessionStatus.waiting) &&
          (selectedDevice == null || s.target.fingerprint == selectedDevice!.fingerprint),
    );
    final activeReceive = receiveSession != null && receiveSession!.status == SessionStatus.sending ? receiveSession : null;

    if (selectedDevice == null) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            if (selectedFiles.isNotEmpty)
              Card(
                color: colorScheme.primaryContainer,
                child: ListTile(
                  leading: Icon(Icons.attach_file, color: colorScheme.onPrimaryContainer),
                  title: Text(
                    '${selectedFiles.length} file(s) queued — pick a device on the left to send',
                    style: TextStyle(color: colorScheme.onPrimaryContainer),
                  ),
                  trailing: IconButton(
                    onPressed: onClearSelectedFiles,
                    icon: Icon(Icons.close, color: colorScheme.onPrimaryContainer),
                  ),
                ),
              ),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Welcome to ${t.appName}',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Select a device or drop any file or folder here to send.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    TextButton.icon(
                      onPressed: onOpenHistory,
                      icon: const Icon(Icons.history, size: 18),
                      label: const Text('Received files'),
                    ),
                  ],
                ),
              ),
            ),
            if (activeReceive != null)
              _ActiveTransferBar(
                sessionId: activeReceive.sessionId,
                label: 'Receiving from ${activeReceive.senderAlias}',
                files: {for (final f in activeReceive.files.values) f.file.id: f.file.size},
                skippedFileIds: {
                  for (final f in activeReceive.files.values)
                    if (f.desiredName == null) f.file.id,
                },
                onCancel: onCancelReceive,
              )
            else if (activeSend != null)
              _ActiveTransferBar(
                sessionId: activeSend.sessionId,
                label: 'Sending to ${activeSend.target.alias}',
                files: {for (final f in activeSend.files.values) f.file.id: f.file.size},
                skippedFileIds: {
                  for (final f in activeSend.files.values)
                    if (f.token == null) f.file.id,
                },
                onCancel: () => onCancelSend(activeSend.sessionId),
              ),
            for (final pending in pendingSends)
              _PendingSendBar(
                entry: pending,
                onCancel: () => onCancelPending(pending.id),
              ),
          ],
        ),
      );
    }

    final device = selectedDevice!;
    final devicePending = pendingSends.where((p) => p.targetFingerprint == device.fingerprint).toList();
    final recentFiles = history.where((e) => !e.isMessage).take(6).toList();

    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _DeviceAvatar(deviceType: device.device.deviceType, isOnline: device.isOnline, radius: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.displayName,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      device.isOnline ? 'Online' : (device.isFavorite ? 'Favorite · Offline' : 'Remembered · Offline'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  if (selectedFiles.isNotEmpty) ...[
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onSendFiles,
                        icon: const Icon(Icons.send),
                        label: Text(selectedFiles.length == 1 ? 'Send ${selectedFiles.first.name}' : 'Send ${selectedFiles.length} queued files'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Clear queued files',
                      onPressed: onClearSelectedFiles,
                      icon: const Icon(Icons.close),
                    ),
                  ] else ...[
                    FilledButton.icon(
                      onPressed: onSendFiles,
                      icon: const Icon(Icons.insert_drive_file_outlined),
                      label: const Text('Send files'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: onSendFolder,
                      icon: const Icon(Icons.folder_outlined),
                      label: const Text('Send folder'),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'Or drag & drop anywhere in this window',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (activeReceive != null) ...[
            const SizedBox(height: 14),
            _ActiveTransferBar(
              sessionId: activeReceive.sessionId,
              label: 'Receiving from ${activeReceive.senderAlias}',
              files: {for (final f in activeReceive.files.values) f.file.id: f.file.size},
              skippedFileIds: {
                for (final f in activeReceive.files.values)
                  if (f.desiredName == null) f.file.id,
              },
              onCancel: onCancelReceive,
            ),
          ],
          if (activeSend != null) ...[
            const SizedBox(height: 14),
            _ActiveTransferBar(
              sessionId: activeSend.sessionId,
              label: 'Sending to ${activeSend.target.alias}',
              files: {for (final f in activeSend.files.values) f.file.id: f.file.size},
              skippedFileIds: {
                for (final f in activeSend.files.values)
                  if (f.token == null) f.file.id,
              },
              onCancel: () => onCancelSend(activeSend.sessionId),
            ),
          ],
          for (final pending in devicePending) ...[
            const SizedBox(height: 14),
            _PendingSendBar(
              entry: pending,
              onCancel: () => onCancelPending(pending.id),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Text('Recent received files', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton(
                onPressed: onOpenHistory,
                child: const Text('View all'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: recentFiles.isEmpty
                ? Center(
                    child: Text(
                      'No received files yet',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    itemCount: recentFiles.length,
                    itemBuilder: (context, index) {
                      final item = recentFiles[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.insert_drive_file_outlined),
                        title: Text(item.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${item.fileSize.asReadableFileSize} · From ${item.senderAlias}'),
                        onTap: item.path == null ? null : () => unawaited(openFile(context, item.fileType, item.path!)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _DeviceRowTile extends StatelessWidget {
  final _UnifiedDevice entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final void Function(Offset globalPosition)? onSecondaryTap;
  final VoidCallback? onLongPress;

  const _DeviceRowTile({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onToggleFavorite,
    this.onSecondaryTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: onSecondaryTap == null ? null : (details) => onSecondaryTap!(details.globalPosition),
        child: Material(
          color: selected ? colorScheme.secondaryContainer.withValues(alpha: 0.7) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                children: [
                  _DeviceAvatar(deviceType: entry.device.deviceType, isOnline: entry.isOnline, radius: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
                        ),
                        if (!entry.isOnline)
                          Text(
                            entry.isFavorite ? 'Favorite · Offline' : 'Remembered · Offline',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: entry.isFavorite ? 'Remove favorite' : 'Favorite',
                    onPressed: onToggleFavorite,
                    icon: Icon(
                      entry.isFavorite ? Icons.star : Icons.star_border,
                      size: 18,
                      color: entry.isFavorite ? Colors.amber : colorScheme.onSurfaceVariant,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceAvatar extends StatelessWidget {
  final DeviceType deviceType;
  final bool isOnline;
  final double radius;

  const _DeviceAvatar({
    required this.deviceType,
    required this.isOnline,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bg = isOnline ? colorScheme.primary : colorScheme.surfaceContainerHighest;
    final fg = isOnline ? colorScheme.onPrimary : colorScheme.onSurfaceVariant;
    final icon = switch (deviceType) {
      DeviceType.mobile => Icons.smartphone,
      DeviceType.desktop => Icons.computer,
      DeviceType.web => Icons.language,
      DeviceType.headless => Icons.terminal,
      DeviceType.server => Icons.dns,
    };
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: bg,
          foregroundColor: fg,
          child: Icon(icon, size: radius),
        ),
        if (isOnline)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
                border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 1.5),
              ),
            ),
          ),
      ],
    );
  }
}

class _ActiveTransferBar extends StatelessWidget {
  final String sessionId;
  final String label;
  final Map<String, int> files;
  final Set<String> skippedFileIds;
  final VoidCallback onCancel;

  const _ActiveTransferBar({
    required this.sessionId,
    required this.label,
    required this.files,
    required this.skippedFileIds,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final transferState = context.watch(fileTransferProvider);
    int totalBytes = 0;
    int currentBytes = 0;
    for (final entry in files.entries) {
      if (skippedFileIds.contains(entry.key)) {
        continue;
      }
      totalBytes += entry.value;
      final status = transferState.getStatus(sessionId: sessionId, fileId: entry.key);
      if (status == FileStatus.finished) {
        currentBytes += entry.value;
      } else {
        currentBytes += (transferState.getProgress(sessionId: sessionId, fileId: entry.key) * entry.value).round();
      }
    }
    final fraction = totalBytes == 0 ? null : (currentBytes / totalBytes).clamp(0.0, 1.0);
    final percent = totalBytes == 0 ? 0 : ((100 * currentBytes) ~/ totalBytes).clamp(0, 100);

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$label · $percent% (${currentBytes.asReadableFileSize} / ${totalBytes.asReadableFileSize})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                TextButton(
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: fraction),
          ],
        ),
      ),
    );
  }
}

class _PendingSendBar extends StatelessWidget {
  final PendingSendEntry entry;
  final VoidCallback onCancel;

  const _PendingSendBar({
    required this.entry,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final fileCount = entry.files.length;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.waitingForBusy
                        ? 'Queued for ${entry.targetAlias} · waiting for current transfer ($fileCount ${fileCount == 1 ? 'file' : 'files'})'
                        : 'Waiting for ${entry.targetAlias} to connect... ($fileCount ${fileCount == 1 ? 'file' : 'files'})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                TextButton(
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

class _LanDropSettingsPage extends StatelessWidget {
  const _LanDropSettingsPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.settingsTab.title),
      ),
      body: const SettingsTab(),
    );
  }
}

class _UnifiedDevice {
  final String fingerprint;
  final String displayName;
  final Device device;
  final bool isOnline;
  final bool isFavorite;

  const _UnifiedDevice({
    required this.fingerprint,
    required this.displayName,
    required this.device,
    required this.isOnline,
    required this.isFavorite,
  });
}
