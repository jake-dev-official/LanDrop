import 'dart:async';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:localsend_app/config/refena.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/pages/changelog_page.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/whats_new_page.dart';
import 'package:localsend_app/provider/animation_provider.dart';
import 'package:localsend_app/provider/app_arguments_provider.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/known_devices_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/pending_send_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/network/webrtc/signaling_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
// [FOSS_REMOVE_START]
import 'package:localsend_app/provider/purchase_provider.dart';
// [FOSS_REMOVE_END]
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/tv_provider.dart';
import 'package:localsend_app/provider/version_provider.dart';
import 'package:localsend_app/provider/window_dimensions_provider.dart';
import 'package:localsend_app/util/changelog.dart';
import 'package:localsend_app/util/i18n.dart';
import 'package:localsend_app/util/native/autostart_helper.dart';
import 'package:localsend_app/util/native/cache_helper.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:localsend_app/util/native/context_menu_helper.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/device_info_helper.dart';
import 'package:localsend_app/util/native/exit_helper.dart';
import 'package:localsend_app/util/native/headless_send_helper.dart';
import 'package:localsend_app/util/native/macos_channel.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/util/native/windows_device_cache.dart';
import 'package:localsend_app/util/notification_strings.dart';
import 'package:localsend_app/util/ui/dynamic_colors.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/dialogs/local_network_dialog.dart';
import 'package:localsend_app/widget/dialogs/whats_new_dialog.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/logging.dart' as rust_logging;
import 'package:localsend_isolates/util/logger.dart';
import 'package:localsend_isolates/util/rust_init.dart';
import 'package:localsend_isolates/util/show_instance.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:share_handler/share_handler.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('Init');
bool _discoveryListenerStarted = false;
bool _androidCancelHandlerRegistered = false;
bool _cacheClearedOnce = false;

/// Will be called before the MaterialApp started
Future<RefenaContainer> preInit(List<String> args) async {
  if (kDebugMode) {
    // Lets the Marionette MCP server drive the app (tap, scroll, screenshot).
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }

  initLogger(args.contains('-v') || args.contains('--verbose') ? Level.ALL : Level.INFO);

  if (checkPlatform([TargetPlatform.linux])) {
    try {
      cacheWaylandStatus(await isWaylandDisplay());
    } catch (e) {
      _logger.warning('Reading display backend failed; using session type: $e');
    }
  }

  MapperContainer.globals.use(const FileDtoMapper());

  await initRustLib();

  if (kDebugMode) {
    try {
      await rust_logging.enableDebugLogging();
    } catch (e) {
      _logger.warning('Enabling debug logging failed', e);
    }
  }

  final dynamicColors = await getDynamicColors();

  final persistenceService = await PersistenceService.initialize(
    supportsDynamicColors: dynamicColors != null,
  );

  if (defaultTargetPlatform == TargetPlatform.windows) {
    // Remove legacy SendTo shortcut; LanDrop uses the Windows 11 shell extension.
    await disableContextMenu();
  }

  await initI18n();

  TransferNotification.init(notificationStrings);

  bool startHidden = false;
  if (checkPlatformIsDesktop()) {
    // Check if this app is already open and let it "show up".
    // If this is the case, then exit the current instance.

    final handedOver = await notifyRunningInstance(
      securityContext: persistenceService.getSecurityContext(),
      port: persistenceService.getPort(),
      https: persistenceService.isHttps(),
      showToken: persistenceService.getShowToken(),
      args: args,
    );
    if (handedOver) {
      await exitApp(); // Another instance does exist
    }

    // initialize tray AFTER i18n has been initialized
    try {
      await initTray();
    } catch (e) {
      _logger.warning('Initializing tray failed: $e');
    }

    // initialize size and position
    await WindowManager.instance.ensureInitialized();
    if (checkPlatformIsNotWaylandDesktop()) {
      await windowManager.setAlwaysOnTop(persistenceService.getAlwaysOnTop());
    }
    await WindowDimensionsController(persistenceService).initDimensionsConfiguration();
    if (args.contains(startHiddenFlag) || (parseSendToArgs(args) != null && persistenceService.isSilentCompletion())) {
      // keep this app hidden
      startHidden = true;
    } else if (defaultTargetPlatform == TargetPlatform.macOS) {
      startHidden = await isLaunchedAsLoginItem() && await getLaunchAtLoginMinimized();
    }

    if (startHidden) {
      unawaited(hideToTray());
    } else {
      unawaited(showFromTray());
    }

    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await setupStatusBar();
    }
  }

  setDefaultRouteTransition();

  final container = RefenaContainer(
    observers: kDebugMode ? [CustomRefenaObserver()] : [],
    overrides: [
      persistenceProvider.overrideWithValue(persistenceService),
      deviceRawInfoProvider.overrideWithValue(await getDeviceInfo()),
      appArgumentsProvider.overrideWithValue(args),
      tvProvider.overrideWithValue(await checkIfTv()),
      dynamicColorsProvider.overrideWithValue(dynamicColors),
      sleepProvider.overrideWithInitialState((ref) => startHidden),
    ],
    platformHint: RefenaScope.getPlatformHint(), // help Refena know the correct platform
  );

  // compatibility for Routerino. TODO: Remove Routerino
  Routerino.navigatorKey = container.read(navigationProvider).key;

  // initialize multi-threading
  await container.set(
    parentIsolateProvider.overrideWithNotifier((ref) {
      final settings = ref.read(settingsProvider);
      return IsolateController(
        initialState: ParentIsolateState.initial(
          SyncState(
            rootIsolateToken: RootIsolateToken.instance!,
            securityContext: persistenceService.getSecurityContext(),
            deviceInfo: ref.read(deviceInfoProvider),
            alias: settings.alias,
            port: settings.port,
            networkWhitelist: settings.networkWhitelist,
            networkBlacklist: settings.networkBlacklist,
            protocol: settings.https ? ProtocolType.https : ProtocolType.http,
            multicastGroup: settings.multicastGroup,
            discoveryTimeout: settings.discoveryTimeout,
            serverRunning: true,
            download: false,
          ),
        ),
      );
    }),
  );

  if (defaultTargetPlatform == TargetPlatform.windows && !persistenceService.isPortableMode()) {
    if (!persistenceService.isAutoStartInitialized()) {
      await enableAutoStart(startHidden: true);
      await persistenceService.setAutoStartInitialized(true);
    }
  }

  await container.redux(parentIsolateProvider).dispatchAsync(IsolateSetupAction());

  if (checkPlatform([TargetPlatform.android])) {
    if (!_androidCancelHandlerRegistered) {
      _androidCancelHandlerRegistered = true;
      registerAndroidCancelTransferHandler(() {
        final receiveSession = container.read(serverProvider)?.session;
        if (receiveSession != null) {
          if (receiveSession.status == SessionStatus.waiting) {
            container.notifier(serverProvider).declineFileRequest();
          } else {
            container.notifier(serverProvider).cancelSession();
          }
        }
        final sendSessions = container.read(sendProvider);
        for (final session in sendSessions.values.toList()) {
          container.notifier(sendProvider).cancelSession(session.sessionId);
        }
      });
    }

    try {
      await container.notifier(serverProvider).startServerFromSettings();
    } catch (e) {
      _logger.warning('Headless Android server start failed', e);
    }

    if (container.read(settingsProvider).backgroundKeepAlive) {
      TransferNotification.setKeepAlive(
        enabled: true,
        channelName: 'LanDrop Background',
        idleTitle: 'LanDrop ready',
        idleText: 'Listening on local network',
      );
    }

    if (!_discoveryListenerStarted) {
      _discoveryListenerStarted = true;
      try {
        container.redux(nearbyDevicesProvider).dispatchAsync(StartDiscoveryListener()); // ignore: unawaited_futures
      } catch (e) {
        _logger.warning('Starting discovery listener failed', e);
      }
    }
  }

  return container;
}

StreamSubscription? _sharedMediaSubscription;

/// Will be called when home page has been initialized
Future<void> postInit(BuildContext context, Ref ref, bool appStart) async {
  await updateSystemOverlayStyle(context);

  if (checkPlatform([TargetPlatform.android])) {
    // On some TVs, requesting a high refresh rate can trigger HDMI resync and blank the display when entering or leaving the app.
    // https://github.com/localsend/localsend/issues/3452
    if (!ref.read(tvProvider)) {
      try {
        await FlutterDisplayMode.setHighRefreshRate();
      } catch (e) {
        _logger.warning('Setting high refresh rate failed', e);
      }
    }

    // Android 17+ blocks multicast discovery and LAN connections until this permission is granted,
    // so ask before the server and discovery start.
    final localNetworkGranted = await requestLocalNetworkPermissionAndroid();
    if (!localNetworkGranted) {
      _logger.warning('Local network permission denied. Discovery and transfers may not work.');
      if (context.mounted) {
        await context.pushBottomSheet(() => const LocalNetworkDialog());
      }
    }
  }

  try {
    await ref.notifier(serverProvider).startServerFromSettings();
  } catch (e) {
    if (context.mounted) {
      context.showSnackBar(e.toString());
    }
  }

  if (checkPlatform([TargetPlatform.android]) && ref.read(settingsProvider).backgroundKeepAlive) {
    TransferNotification.setKeepAlive(
      enabled: true,
      channelName: 'LanDrop Background',
      idleTitle: 'LanDrop ready',
      idleText: 'Listening on local network',
    );
  }

  if (checkPlatform([TargetPlatform.windows])) {
    unawaited(
      syncWindowsDeviceCache(
        favorites: ref.read(favoritesProvider),
        nearbyDevices: ref.read(nearbyDevicesProvider).devices,
        knownDevices: ref.read(knownDevicesProvider),
      ),
    );
  }

  if (!_discoveryListenerStarted) {
    _discoveryListenerStarted = true;
    try {
      ref.redux(nearbyDevicesProvider).dispatchAsync(StartDiscoveryListener()); // ignore: unawaited_futures
    } catch (e) {
      _logger.warning('Starting discovery listener failed', e);
    }
  }

  // ignore: dead_code
  if (webRTCEnabled) {
    ref.redux(signalingProvider).dispatch(SetupSignalingConnection());
  }

  if (appStart) {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      // handle dropped files
      pendingFilesStream.listen((files) async {
        await ref.global.dispatchAsync(
          _HandleAppStartArgumentsAction(
            args: files,
          ),
        );
      });

      // handle dropped strings
      pendingStringsStream.listen((pendingStrings) {
        for (final string in pendingStrings) {
          ref.redux(selectedSendingFilesProvider).dispatch(AddMessageAction(message: string));
        }
        ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
      });

      await setupMethodCallHandler();
    } else {
      final args = ref.read(appArgumentsProvider);
      await ref.global.dispatchAsync(
        _HandleAppStartArgumentsAction(
          args: args,
        ),
      );
    }
  }

  bool hasInitialShare = false;

  if (checkPlatformCanReceiveShareIntent()) {
    final shareHandler = ShareHandlerPlatform.instance;

    if (appStart) {
      final initialSharedPayload = await shareHandler.getInitialSharedMedia();
      if (initialSharedPayload != null) {
        hasInitialShare = true;
        // ignore: unawaited_futures
        ref.global.dispatchAsync(
          _HandleShareIntentAction(
            payload: initialSharedPayload,
          ),
        );
      }
    }

    _sharedMediaSubscription?.cancel(); // ignore: unawaited_futures
    _sharedMediaSubscription = shareHandler.sharedMediaStream.listen((SharedMedia payload) async {
      hasInitialShare = true;
      await ref.global.dispatchAsync(
        _HandleShareIntentAction(
          payload: payload,
        ),
      );
    });

    if (checkPlatform([TargetPlatform.android])) {
      // Both messages above travel through the same messenger in order, so the stream is
      // guaranteed to be attached natively before MainActivity replays held-back intents.
      await flushPendingShareIntentsAndroid();
    }
  }

  final hasActiveFiles =
      ref.read(selectedSendingFilesProvider).isNotEmpty || ref.read(sendProvider).isNotEmpty || ref.read(pendingSendProvider).isNotEmpty;
  if (appStart && !_cacheClearedOnce && !hasInitialShare && !hasActiveFiles && (checkPlatformWithGallery() || checkPlatformCanReceiveShareIntent())) {
    // Clear cache on first app start when no shared media or active transfer is in flight.
    _cacheClearedOnce = true;
    ref.global.dispatchAsync(ClearCacheAction()); // ignore: unawaited_futures
  }

  final version = (await ref.future(versionProvider)).version;
  if (!ref.read(persistenceProvider).isFirstAppStart) {
    final lastVersion = ref.read(persistenceProvider).getWhatsNew();
    WhatsNewPage? whatsNew = WhatsNewPage.fromLastVersion(lastVersion: lastVersion);
    if (whatsNew != null) {
      // ignore: unawaited_futures
      ref.global.dispatchAsync(NavigateAction.push(whatsNew));
    } else if (lastVersion != null && isNewerVersion(version, lastVersion)) {
      final releases = parseChangelog(await rootBundle.loadString(Assets.changelog));
      final release = releases.where((release) => release.version == version).firstOrNull;
      if (release != null && context.mounted) {
        // ignore: unawaited_futures
        WhatsNewDialog.open(context, release).then((showChangelog) async {
          if (showChangelog) {
            await ref.global.dispatchAsync(NavigateAction.push(const ChangelogPage()));
          }
        });
      }
    }
  }

  await ref.read(persistenceProvider).setWhatsNew(version);

  // [FOSS_REMOVE_START]
  if (checkPlatformSupportPayment()) {
    // ignore: unawaited_futures
    ref.redux(purchaseProvider).dispatchAsync(InitPurchaseStream());
  }
  // [FOSS_REMOVE_END]
}

class _HandleShareIntentAction extends AsyncGlobalAction {
  final SharedMedia payload;

  _HandleShareIntentAction({
    required this.payload,
  });

  @override
  Future<void> reduce() async {
    final message = payload.content;
    if (message != null && message.trim().isNotEmpty) {
      ref.redux(selectedSendingFilesProvider).dispatch(AddMessageAction(message: message));
    }
    await ref
        .redux(selectedSendingFilesProvider)
        .dispatchAsync(
          AddFilesAction(
            files: payload.attachments?.where((a) => a != null).cast<SharedAttachment>() ?? <SharedAttachment>[],
            converter: CrossFileConverters.convertSharedAttachment,
          ),
        );

    ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
  }
}

class _HandleAppStartArgumentsAction extends AsyncGlobalAction {
  final List<String> args;

  _HandleAppStartArgumentsAction({
    required this.args,
  });

  @override
  Future<void> reduce() async {
    final sendTo = parseSendToArgs(args);
    if (sendTo != null) {
      await executeHeadlessSend(ref, sendTo);
      return;
    }
    final filesAdded = await ref.redux(selectedSendingFilesProvider).dispatchAsyncTakeResult(LoadSelectionFromArgsAction(args));
    if (filesAdded) {
      ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
    }
  }
}
