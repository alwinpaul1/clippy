import 'package:clippy/platform/foreground_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Host-side tests for the Android background-sync service state machine
/// (normally Android-only; [ForegroundServiceManager.debugIsAndroid] points the
/// platform gate at the test). The plugin is faked at its method channel, so
/// these exercise the REAL logic: the stale-service-type migration that makes
/// the specialUse fix actually stick, and the liveness signal the UI shows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_foreground_task/methods');
  late List<String> calls;
  late bool serviceRunning;
  // What the next startService() will produce — the system can refuse it.
  late bool startSucceeds;

  setUp(() {
    calls = [];
    serviceRunning = false;
    startSucceeds = true;
    SharedPreferences.setMockInitialValues({});
    ForegroundServiceManager.debugIsAndroid = true;
    ForegroundServiceManager.backgroundSyncAlive.value = true;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'isRunningService':
          return serviceRunning;
        case 'startService':
          serviceRunning = startSucceeds;
          return null;
        case 'stopService':
          serviceRunning = false;
          return null;
        case 'isIgnoringBatteryOptimizations':
          return true; // already exempt — not what these tests are about
        default:
          return null;
      }
    });

    ForegroundServiceManager.init();
  });

  tearDown(() {
    ForegroundServiceManager.stopHealthWatch();
    ForegroundServiceManager.debugIsAndroid = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// The plugin persists the service type in ITS own prefs and replays it on
  /// boot — it never reads the manifest. An install still carrying the old
  /// dataSync value restarts with a type the manifest no longer declares, the
  /// system kills the service, and the 6h-outage bug is silently back. Only a
  /// stop+start rewrites those options.
  test('a stale persisted service type forces a stop+start (the migration '
      'that makes the specialUse fix stick)', () async {
    SharedPreferences.setMockInitialValues({'fgs_service_types_version': 1});
    serviceRunning = true; // running under the OLD type

    await ForegroundServiceManager.start();

    expect(calls, containsAllInOrder(['stopService', 'startService']),
        reason: 'the old options must be torn down before the new type is '
            'written, or the stale type survives the update');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('fgs_service_types_version'), 2,
        reason: 'the migration must record that it ran');
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isTrue);
  });

  test('an install with NO recorded version is treated as stale (every '
      'pre-1.0.30 phone)', () async {
    SharedPreferences.setMockInitialValues({}); // never migrated
    serviceRunning = true;

    await ForegroundServiceManager.start();

    expect(calls, contains('stopService'),
        reason: 'absent version means the legacy dataSync type — migrate it');
    expect(calls, contains('startService'));
  });

  test('an already-migrated running service is left alone (no restart storm)',
      () async {
    SharedPreferences.setMockInitialValues({'fgs_service_types_version': 2});
    serviceRunning = true;

    await ForegroundServiceManager.start();

    expect(calls, isNot(contains('stopService')));
    expect(calls, isNot(contains('startService')),
        reason: 'restarting a healthy service on every launch would drop the '
            'relay link for no reason');
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isTrue);
  });

  test('a dead service is started, and the notifier reports the real outcome',
      () async {
    serviceRunning = false;

    await ForegroundServiceManager.start();

    expect(calls, contains('startService'));
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isTrue);
  });

  test('a service the system REFUSES to start is reported as not alive — the '
      'UI must not show a green light over a dead service', () async {
    serviceRunning = false;
    startSucceeds = false; // e.g. a platform restriction refuses it

    await ForegroundServiceManager.start();

    expect(ForegroundServiceManager.backgroundSyncAlive.value, isFalse,
        reason: 'this is the whole point: never claim sync is healthy when it '
            'is not');
  });

  test('ensureRunning revives a service that died while the app was away',
      () async {
    SharedPreferences.setMockInitialValues({'fgs_service_types_version': 2});
    serviceRunning = false; // killed by the OEM battery manager

    await ForegroundServiceManager.ensureRunning();

    expect(calls, contains('startService'));
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isTrue);
  });

  test('ensureRunning is a no-op when the service is already up', () async {
    SharedPreferences.setMockInitialValues({'fgs_service_types_version': 2});
    serviceRunning = true;

    await ForegroundServiceManager.ensureRunning();

    expect(calls, isNot(contains('startService')));
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isTrue);
  });

  test('the health watch notices a service killed WHILE the app is open',
      () async {
    ForegroundServiceManager.healthPollInterval =
        const Duration(milliseconds: 20);
    addTearDown(() => ForegroundServiceManager.healthPollInterval =
        const Duration(seconds: 20));
    serviceRunning = true;
    ForegroundServiceManager.startHealthWatch();

    serviceRunning = false; // Samsung sleeps it while the user is looking
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(ForegroundServiceManager.backgroundSyncAlive.value, isFalse,
        reason: 'a resume-only check would keep showing "Synced" until the '
            'next lifecycle transition — the lie this change exists to stop');
  });

  test('stopHealthWatch cancels the poll (no timer leak past the foreground)',
      () async {
    ForegroundServiceManager.healthPollInterval =
        const Duration(milliseconds: 20);
    addTearDown(() => ForegroundServiceManager.healthPollInterval =
        const Duration(seconds: 20));
    serviceRunning = true;
    ForegroundServiceManager.startHealthWatch();
    ForegroundServiceManager.stopHealthWatch();

    serviceRunning = false;
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(ForegroundServiceManager.backgroundSyncAlive.value, isTrue,
        reason: 'a cancelled watch must not keep polling in the background');
  });

  test('every entry point is a no-op off Android (desktop must not touch the '
      'plugin)', () async {
    ForegroundServiceManager.debugIsAndroid = false;

    await ForegroundServiceManager.start();
    await ForegroundServiceManager.ensureRunning();
    ForegroundServiceManager.startHealthWatch();

    expect(calls, isEmpty);
  });
}
