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
  // Faithful to the native plugin: stopService() only DISPATCHES an intent, so
  // isRunningService keeps reporting true for a while afterwards.
  late bool stopIsAsync;
  late bool throwOnStart;
  // A stop that never lands: the plugin's 5s state-change check fails and it
  // returns ServiceRequestFailure, leaving the OLD service running.
  late bool stopFails;
  late bool batteryExempt;
  var pollsAfterStop = 0;

  setUp(() {
    calls = [];
    serviceRunning = false;
    startSucceeds = true;
    stopIsAsync = false;
    throwOnStart = false;
    stopFails = false;
    batteryExempt = true;
    pollsAfterStop = 0;
    SharedPreferences.setMockInitialValues({});
    ForegroundServiceManager.resetForTests(); // no static bleed between tests
    ForegroundServiceManager.debugIsAndroid = true;
    // Seed the OPPOSITE of the healthy answer: seeding `true` made every
    // isTrue assertion below pass even with the production publishing deleted.
    ForegroundServiceManager.backgroundSyncAlive.value = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'isRunningService':
          if (pollsAfterStop > 0) {
            pollsAfterStop--; // the stop intent hasn't been processed yet
            return true;
          }
          return serviceRunning;
        case 'startService':
          if (throwOnStart) {
            throw PlatformException(code: 'FGS_START_NOT_ALLOWED');
          }
          serviceRunning = startSucceeds;
          return null;
        case 'stopService':
          if (stopFails) return null; // service stays up → plugin reports failure
          serviceRunning = false;
          if (stopIsAsync) pollsAfterStop = 3; // lands a few polls later
          return null;
        case 'isIgnoringBatteryOptimizations':
          return batteryExempt;
        default:
          return null;
      }
    });

    ForegroundServiceManager.init();
  });

  tearDown(() {
    ForegroundServiceManager.resetForTests();
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

  test('a service killed while the app is open and IMPOSSIBLE to revive is '
      'reported as dead (never a green light over a dead service)', () async {
    ForegroundServiceManager.healthPollInterval =
        const Duration(milliseconds: 20);
    addTearDown(() => ForegroundServiceManager.healthPollInterval =
        const Duration(seconds: 20));
    SharedPreferences.setMockInitialValues({'fgs_service_types_version': 2});
    serviceRunning = true;
    ForegroundServiceManager.startHealthWatch();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    serviceRunning = false; // Samsung sleeps it while the user is looking
    startSucceeds = false; // ...and the system refuses to bring it back
    await Future<void>.delayed(const Duration(milliseconds: 120));

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
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isTrue);

    ForegroundServiceManager.stopHealthWatch();
    // Let any poll that was already in flight at cancel time settle first, so
    // this asserts "no NEW polls", not "no call ever resolves again".
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final settled = calls.length;
    serviceRunning = false;
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(calls.length, settled,
        reason: 'a cancelled watch must not keep polling in the background');
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isTrue,
        reason: 'and an in-flight poll must not publish after cancellation');
  });

  /// The plugin's stopService() only DISPATCHES a stop intent; isRunningService
  /// keeps reporting true until the service processes it. startService() throws
  /// ServiceAlreadyStartedException while that is still true — so the migration
  /// must wait for the stop to actually land.
  test('the migration waits for the async stop to land before starting '
      '(stopService is only a dispatched intent)', () async {
    SharedPreferences.setMockInitialValues({'fgs_service_types_version': 1});
    serviceRunning = true;
    stopIsAsync = true; // isRunningService stays true for a few polls

    await ForegroundServiceManager.start();

    expect(calls, containsAllInOrder(['stopService', 'startService']));
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isTrue,
        reason: 'the migration must survive an asynchronous stop, not throw '
            'ServiceAlreadyStartedException into ClipController.init()');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('fgs_service_types_version'), 2);
  });

  test('start() never throws when the plugin does — a refused service must not '
      'take app init down with it', () async {
    throwOnStart = true; // the system refuses the foreground-service start

    await expectLater(ForegroundServiceManager.start(), completes);
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isFalse,
        reason: 'init() awaits start() BEFORE wiring the lifecycle observer '
            'and screenshot sync — an escape here silently breaks both');
  });

  test('a failed start is NOT recorded as migrated (it retries next launch)',
      () async {
    SharedPreferences.setMockInitialValues({'fgs_service_types_version': 1});
    serviceRunning = false;
    startSucceeds = false; // start "succeeds" but the service never comes up

    await ForegroundServiceManager.start();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('fgs_service_types_version'), 1,
        reason: 'remembering a migration that never happened would strand the '
            'phone on the stale type forever');
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isFalse);
  });

  /// The plugin NEVER throws: start/stop return a ServiceRequestResult with the
  /// error folded inside. A stop that times out leaves the OLD service running,
  /// so asking `isRunningService` afterwards answers "yes" about the very
  /// service we were replacing.
  test('a FAILED stop is not mistaken for a successful migration (the old '
      'service is still running on the stale type)', () async {
    SharedPreferences.setMockInitialValues({'fgs_service_types_version': 1});
    serviceRunning = true;
    stopFails = true; // the stop never lands; the old service stays up

    await ForegroundServiceManager.start();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('fgs_service_types_version'), 1,
        reason: 'recording this as migrated would strand the phone on dataSync '
            'forever — the next launch must retry');
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isFalse,
        reason: 'the running service is the STALE one; do not vouch for it');
  });

  test('the health watch REVIVES a service that died while the app is open, '
      'not just reports it', () async {
    ForegroundServiceManager.healthPollInterval =
        const Duration(milliseconds: 20);
    addTearDown(() => ForegroundServiceManager.healthPollInterval =
        const Duration(seconds: 20));
    SharedPreferences.setMockInitialValues({'fgs_service_types_version': 2});
    serviceRunning = true;
    ForegroundServiceManager.startHealthWatch();

    serviceRunning = false; // the OEM battery manager kills it, app still open
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(calls, contains('startService'),
        reason: 'the user is LOOKING at the app — telling them to "open" it is '
            'not an instruction they can follow; repair it');
    expect(ForegroundServiceManager.backgroundSyncAlive.value, isTrue,
        reason: 'and once revived, say so');
  });

  // NOT tested here: the battery-exemption request. The plugin gates
  // isIgnoringBatteryOptimizations on the REAL Platform.isAndroid and returns
  // true off-device, so the branch is unreachable from a host test. What the
  // code guarantees instead — that the request cannot stall start() behind its
  // system dialog — is structural: it is fired unawaited AFTER the service is
  // up (see _askBatteryExemption).
  test('a service the system keeps refusing is retried with BACKOFF, not on '
      'every poll (that would just burn battery)', () async {
    ForegroundServiceManager.healthPollInterval =
        const Duration(milliseconds: 10);
    addTearDown(() => ForegroundServiceManager.healthPollInterval =
        const Duration(seconds: 20));
    SharedPreferences.setMockInitialValues({'fgs_service_types_version': 2});
    serviceRunning = false;
    // The system REFUSES the start outright (ForegroundServiceStartNotAllowed).
    // This fails fast — unlike a start that merely never comes up, which the
    // plugin's own 5s state-change deadline already throttles for us.
    throwOnStart = true;

    ForegroundServiceManager.startHealthWatch();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final polls = calls.where((c) => c == 'isRunningService').length;
    final attempts = calls.where((c) => c == 'startService').length;
    expect(attempts, greaterThan(0), reason: 'it must still try');
    expect(attempts, lessThan(polls ~/ 4),
        reason: 'without backoff every single poll would fire another doomed '
            'restart at a system that is flatly refusing');
  });

  test('start() does not block on the battery-exemption dialog', () async {
    batteryExempt = false;

    await ForegroundServiceManager.start().timeout(const Duration(seconds: 2));

    expect(calls, contains('startService'),
        reason: 'the service must come up without waiting for the user to '
            'answer a settings dialog — ClipController.init() has not yet '
            'registered the lifecycle observer at this point');
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
