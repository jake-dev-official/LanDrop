import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:refena_inspector_client/refena_inspector_client.dart';

final _logger = Logger('Refena');

class CustomRefenaObserver extends RefenaMultiObserver {
  CustomRefenaObserver()
    : super(
        observers: [
          RefenaDebugObserver(
            onLine: (line) => _logger.info(line),
            exclude: _exclude,
          ),
          RefenaTracingObserver(
            limit: 100,
            exclude: _exclude,
          ),
          RefenaInspectorObserver(),
        ],
      );
}

/// Refena 3.5.0 only invokes provider `onChanged` callbacks when at least one
/// observer is attached to the [RefenaContainer]. Keep a zero-overhead observer
/// in release builds so `onChanged` listeners stay active.
class ReleaseNoopRefenaObserver extends RefenaObserver {
  @override
  void handleEvent(RefenaEvent event) {}
}

bool _exclude(RefenaEvent event) {
  return switch (event) {
    ChangeEvent() => event.notifier is DiscoveryLogger || event.notifier is LocalIpService || event.notifier is FileTransferNotifier,
    ActionDispatchedEvent() => event.action.runtimeType.toString() == '_FetchLocalIpAction',
    ActionFinishedEvent() => event.action.runtimeType.toString() == '_FetchLocalIpAction',
    _ => false,
  };
}
