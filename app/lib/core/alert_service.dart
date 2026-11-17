import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'hub.dart';

/// Phone notifications over the app's own connection (2026-11-16: no Home Assistant). An Android foreground
/// service keeps a second copy of the network code running while the app is closed; it holds the events sockets to
/// every computer (directly or through a relay) and turns Goblin alerts into notifications. While the app is on
/// screen it stays quiet: the app shows its own banner.
class AlertService {
  static const _channel = AndroidNotificationChannel('alerts', 'Chat alerts',
      description: 'A chat needs permission, has a question, or finished', importance: Importance.high);
  static final notifications = FlutterLocalNotificationsPlugin();

  /// Payload of a tapped notification: "node|pane".
  static final taps = StreamController<String>.broadcast();

  /// Main isolate, Android only: notification permission, the service, and taps.
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    await notifications.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload != null) taps.add(r.payload!);
      },
    );
    final launch = await notifications.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true && launch?.notificationResponse?.payload != null) {
      Timer(const Duration(milliseconds: 600), () => taps.add(launch!.notificationResponse!.payload!));
    }
    await notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'connection',
        channelName: 'Connection',
        channelDescription: 'Keeps Switchboard connected so chat alerts arrive',
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization(); // Samsung kills it otherwise
    }
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService(); // picks up a new pairing / new code
    } else {
      await FlutterForegroundTask.startService(
        serviceId: 4711,
        serviceTypes: [ForegroundServiceTypes.remoteMessaging],
        notificationTitle: 'Switchboard',
        notificationText: 'Connected for chat alerts',
        callback: alertTaskMain,
      );
    }
  }

  static Future<void> stop() async {
    if (Platform.isAndroid && await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
  }

  /// Tell the service whether the app is on screen (then it does not notify).
  static void visible(bool v) {
    if (Platform.isAndroid) FlutterForegroundTask.sendDataToTask(v ? 'fg' : 'bg');
  }
}

@pragma('vm:entry-point')
void alertTaskMain() {
  FlutterForegroundTask.setTaskHandler(AlertTask());
}

/// The service side: its own Fleet, never paused.
class AlertTask extends TaskHandler {
  Fleet? _fleet;
  StreamSubscription<Alert>? _sub;
  bool _appVisible = false;
  final _seen = <String>{};
  Timer? _status;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    DartPluginRegistrant.ensureInitialized();
    await AlertService.notifications.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    final f = Fleet();
    _fleet = f;
    await f.load();
    if (!f.paired) return;
    _sub = f.newAlerts.listen(_notify);
    await f.start();
    _status = Timer.periodic(const Duration(seconds: 30), (_) => _updateText());
    _updateText();
  }

  void _updateText() {
    final f = _fleet;
    if (f == null) return;
    final on = f.nodes.where((n) => n.link == LinkState.online).length;
    FlutterForegroundTask.updateService(
        notificationTitle: 'Switchboard', notificationText: 'Connected to $on of ${f.nodes.length} computers');
  }

  Future<void> _notify(Alert a) async {
    final key = '${a.node?.id}|${a.id}';
    if (_appVisible || !_seen.add(key)) return;
    final who = a.sessionName?.isNotEmpty == true ? a.sessionName! : (a.kind ?? 'Chat');
    final where = a.node?.name ?? '';
    try {
      await AlertService.notifications.show(
        id: '${a.node?.id}|${a.pane}'.hashCode & 0x7fffffff, // one per chat: a newer alert replaces the older
        title: '$who${where.isEmpty ? '' : ' · $where'}: ${a.title}',
        body: a.body.isEmpty ? null : a.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(AlertService._channel.id, AlertService._channel.name,
              channelDescription: AlertService._channel.description,
              importance: a.type == 'done' ? Importance.defaultImportance : Importance.high,
              priority: a.type == 'done' ? Priority.defaultPriority : Priority.high,
              styleInformation: BigTextStyleInformation(a.body),
              tag: 'chat'),
        ),
        payload: '${a.node?.id ?? ''}|${a.pane ?? ''}',
      );
    } catch (_) {}
  }

  @override
  void onReceiveData(Object data) {
    if (data == 'fg') _appVisible = true;
    if (data == 'bg') _appVisible = false;
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _status?.cancel();
    await _sub?.cancel();
    _fleet?.dispose();
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}
