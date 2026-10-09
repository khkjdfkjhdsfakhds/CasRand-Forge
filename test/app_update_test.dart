import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:crypto/crypto.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nai_casrand/data/services/app_update_installer.dart';
import 'package:nai_casrand/data/services/app_update_service.dart';
import 'package:nai_casrand/ui/app_update/app_update_controller.dart';
import 'package:nai_casrand/ui/app_update/app_update_dialog.dart';
import 'package:nai_casrand/ui/app_update/app_update_settings_tiles.dart';

final _packageBytes = utf8.encode('fake package payload');
final _packageSha = sha256.convert(_packageBytes).toString();

Map<String, dynamic> _releaseJson({
  String tag = 'v1.02',
  bool prerelease = false,
  bool withDigest = true,
}) {
  Map<String, dynamic> asset(String name) => {
        'name': name,
        'size': _packageBytes.length,
        'browser_download_url':
            'https://github.com/$appUpdateRepository/releases/download/$tag/$name',
        if (withDigest) 'digest': 'sha256:$_packageSha',
      };
  return {
    'tag_name': tag,
    'name': 'CasRand Forge $tag',
    'body': '- New feature\n- Bug fix',
    'html_url': 'https://github.com/$appUpdateRepository/releases/tag/$tag',
    'published_at': '2026-10-10T08:00:00Z',
    'draft': false,
    'prerelease': prerelease,
    'assets': [
      asset('NAI-CasRand-Forge-$tag-Android.apk'),
      asset('NAI-CasRand-Forge-$tag-macOS-universal.dmg'),
      asset('NAI-CasRand-Forge-$tag-Windows-x64.zip'),
      asset('SHA256SUMS.txt'),
    ],
  };
}

/// GitHub stand-in that counts package downloads.
class _FakeGitHub {
  _FakeGitHub({
    this.apiStatus = 200,
    Map<String, dynamic>? release,
    this.packageBytes,
  }) : release = release ?? _releaseJson();

  int apiStatus;
  Map<String, dynamic> release;
  List<int>? packageBytes;
  int packageDownloads = 0;
  String redirectTag = 'v1.02';

  http.Client client(String proxy) => MockClient.streaming((request, _) async {
        final url = request.url.toString();
        if (url.startsWith('https://api.github.com/')) {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(release))),
            apiStatus,
          );
        }
        if (url == appUpdateLatestReleaseUrl) {
          return http.StreamedResponse(const Stream.empty(), 302, headers: {
            'location':
                'https://github.com/$appUpdateRepository/releases/tag/$redirectTag',
          });
        }
        if (url.endsWith('SHA256SUMS.txt')) {
          final names = [
            'NAI-CasRand-Forge-$redirectTag-Android.apk',
            'NAI-CasRand-Forge-$redirectTag-macOS-universal.dmg',
            'NAI-CasRand-Forge-$redirectTag-Windows-x64.zip',
          ];
          return http.StreamedResponse(
            Stream.value(utf8
                .encode(names.map((name) => '$_packageSha  $name\n').join())),
            200,
          );
        }
        packageDownloads++;
        final bytes = packageBytes ?? _packageBytes;
        return http.StreamedResponse(
          Stream.fromIterable([bytes.sublist(0, 4), bytes.sublist(4)]),
          200,
          contentLength: bytes.length,
        );
      });
}

class _FakeInstaller extends AppUpdateInstaller {
  _FakeInstaller(this.dir,
      {this.outcome = UpdateInstallOutcome.restartRequired})
      : super(platform: TargetPlatform.macOS);

  final Directory dir;
  final UpdateInstallOutcome outcome;
  final installed = <String>[];
  int helperLaunches = 0;
  int cleanups = 0;

  @override
  Future<Directory> workingDirectory() async => dir;

  @override
  Future<UpdateInstallResult> install(File package, ReleaseInfo release) async {
    installed.add(package.path);
    return UpdateInstallResult(
      outcome,
      launchHelper: () async => helperLaunches++,
      cleanup: () async => cleanups++,
    );
  }
}

void main() {
  group('AppVersion', () {
    test('maps Forge two-part tags to app versions', () {
      expect(AppVersion.tryParse('v1.01'), AppVersion.tryParse('1.0.1'));
      expect(AppVersion.tryParse('v1.00'), const AppVersion(1, 0, 0));
      expect(AppVersion.tryParse('v1.10'), const AppVersion(1, 1, 0));
      expect(AppVersion.tryParse('v0.9.8'), const AppVersion(0, 9, 8));
      expect(AppVersion.tryParse('1.0.1+163'), const AppVersion(1, 0, 1));
    });

    test('orders releases and pre-releases', () {
      final current = AppVersion.tryParse('1.0.1')!;
      expect(AppVersion.tryParse('v1.02')! > current, isTrue);
      expect(AppVersion.tryParse('v1.01')! > current, isFalse);
      expect(AppVersion.tryParse('v1.00')! > current, isFalse);
      expect(AppVersion.tryParse('v0.9.8')! > current, isFalse);
      expect(AppVersion.tryParse('v1.10')! > AppVersion.tryParse('1.0.9')!,
          isTrue);
      expect(
          AppVersion.tryParse('v0.9.4')! >
              AppVersion.tryParse('v0.9.4-beta.5')!,
          isTrue);
    });

    test('rejects malformed versions', () {
      expect(AppVersion.tryParse(''), isNull);
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse('v1..2'), isNull);
      expect(AppVersion.tryParse('1.2.3.4'), isNull);
    });
  });

  group('ReleaseInfo', () {
    test('parses GitHub release JSON with digests', () {
      final release = ReleaseInfo.fromGitHubJson(_releaseJson())!;
      expect(release.version, const AppVersion(1, 0, 2));
      expect(release.notes, contains('New feature'));
      expect(release.assetFor(UpdatePackageKind.macosDmg)!.name,
          endsWith('macOS-universal.dmg'));
      expect(release.assetFor(UpdatePackageKind.windowsZip)!.name,
          endsWith('Windows-x64.zip'));
      final apk = release.assetFor(UpdatePackageKind.androidApk)!;
      expect(apk.sha256, _packageSha);
      expect(apk.size, _packageBytes.length);
      expect(release.checksumAsset, isNotNull);
    });

    test('ignores drafts and pre-releases', () {
      expect(
          ReleaseInfo.fromGitHubJson(_releaseJson(prerelease: true)), isNull);
      expect(ReleaseInfo.fromGitHubJson({..._releaseJson(), 'draft': true}),
          isNull);
    });

    test('builds conventional asset URLs from a tag', () {
      final release = ReleaseInfo.fromTag('v1.02')!;
      expect(
        release.assetFor(UpdatePackageKind.macosDmg)!.downloadUrl.toString(),
        'https://github.com/$appUpdateRepository/releases/download/v1.02/'
        'NAI-CasRand-Forge-v1.02-macOS-universal.dmg',
      );
      expect(release.notes, isEmpty);
    });

    test('parses sha256sum files', () {
      final content = '${'a' * 64}  one.zip\n${'B' * 64} *two.apk\n';
      expect(AppUpdateService.parseChecksumFile(content, 'one.zip'), 'a' * 64);
      expect(AppUpdateService.parseChecksumFile(content, 'two.apk'), 'b' * 64);
      expect(AppUpdateService.parseChecksumFile(content, 'three'), isNull);
    });
  });

  group('AppUpdateService', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('app-update-'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('detects a newer release through the REST API', () async {
      final github = _FakeGitHub();
      final service = AppUpdateService(clientFactory: github.client);
      final result = await service.checkForUpdate(currentVersion: '1.0.1');
      expect(result.hasUpdate, isTrue);
      expect(result.latest.tagName, 'v1.02');

      github.release = _releaseJson(tag: 'v1.01');
      final same = await service.checkForUpdate(currentVersion: '1.0.1');
      expect(same.hasUpdate, isFalse);
    });

    test('falls back to the release redirect when the API is limited',
        () async {
      final github = _FakeGitHub(apiStatus: 403);
      final service = AppUpdateService(clientFactory: github.client);
      final result = await service.checkForUpdate(currentVersion: '1.0.1');
      expect(result.hasUpdate, isTrue);
      final asset = result.latest.assetFor(UpdatePackageKind.windowsZip)!;
      expect(asset.sha256, isNull);
      final sha =
          await service.resolveChecksum(release: result.latest, asset: asset);
      expect(sha, _packageSha);
    });

    test('reports network failures with a stable code', () async {
      final service = AppUpdateService(
        clientFactory: (_) => MockClient((_) async {
          throw const SocketException('offline');
        }),
      );
      expect(
        () => service.checkForUpdate(currentVersion: '1.0.1'),
        throwsA(
            isA<AppUpdateException>().having((e) => e.code, 'code', 'network')),
      );
    });

    test('downloads a verified package', () async {
      final github = _FakeGitHub();
      final service = AppUpdateService(clientFactory: github.client);
      final release = ReleaseInfo.fromGitHubJson(_releaseJson())!;
      final asset = release.assetFor(UpdatePackageKind.androidApk)!;
      final progress = <int>[];
      final file = await service.download(
        asset: asset,
        expectedSha256: _packageSha,
        destination: File('${temp.path}/update.apk'),
        onProgress: (received, _) => progress.add(received),
      );
      expect(file.readAsBytesSync(), _packageBytes);
      expect(progress.last, _packageBytes.length);
      expect(File('${temp.path}/update.apk.part').existsSync(), isFalse);
      expect(await AppUpdateService.fileMatchesChecksum(file, _packageSha),
          isTrue);
    });

    test('discards a package whose checksum does not match', () async {
      final github = _FakeGitHub(packageBytes: utf8.encode('tampered bytes!'));
      final service = AppUpdateService(clientFactory: github.client);
      final release = ReleaseInfo.fromGitHubJson(_releaseJson())!;
      await expectLater(
        service.download(
          asset: release.assetFor(UpdatePackageKind.androidApk)!,
          expectedSha256: _packageSha,
          destination: File('${temp.path}/update.apk'),
        ),
        throwsA(isA<AppUpdateException>()
            .having((e) => e.code, 'code', 'checksum_mismatch')),
      );
      expect(temp.listSync(), isEmpty);
    });

    test('stops a cancelled download without leaving files', () async {
      final github = _FakeGitHub();
      final service = AppUpdateService(clientFactory: github.client);
      final release = ReleaseInfo.fromGitHubJson(_releaseJson())!;
      final token = UpdateCancelToken();
      await expectLater(
        service.download(
          asset: release.assetFor(UpdatePackageKind.androidApk)!,
          expectedSha256: _packageSha,
          destination: File('${temp.path}/update.apk'),
          cancelToken: token,
          onProgress: (received, _) {
            if (received > 0) token.cancel();
          },
        ),
        throwsA(isA<UpdateDownloadCancelled>()),
      );
      expect(temp.listSync(), isEmpty);
    });
  });

  group('AppUpdateController', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('app-update-'));
    tearDown(() => temp.deleteSync(recursive: true));

    AppUpdateController controllerFor(
      _FakeGitHub github,
      _FakeInstaller installer, {
      MemoryAppUpdatePreferences? preferences,
      AppExitResponse exitResponse = AppExitResponse.cancel,
      List<int>? exitRequests,
    }) {
      return AppUpdateController(
        currentVersion: '1.0.1',
        preferences: preferences ?? MemoryAppUpdatePreferences(),
        proxy: () => '',
        service: AppUpdateService(clientFactory: github.client),
        installer: installer,
        requestExit: () async {
          exitRequests?.add(1);
          return exitResponse;
        },
        periodicCheckInterval: Duration.zero,
      );
    }

    test('announces each new version once and honours skipped versions',
        () async {
      final preferences = MemoryAppUpdatePreferences();
      final controller = controllerFor(
        _FakeGitHub(),
        _FakeInstaller(temp),
        preferences: preferences,
      );
      expect((await controller.checkInBackground())?.tagName, 'v1.02');
      expect(await controller.checkInBackground(), isNull);
      expect(controller.updateAvailable, isTrue);

      final fresh = controllerFor(
        _FakeGitHub(),
        _FakeInstaller(temp),
        preferences: preferences,
      );
      await fresh.check();
      fresh.skipLatestVersion();
      expect(preferences.skippedVersion, 'v1.02');
      final again = controllerFor(
        _FakeGitHub(),
        _FakeInstaller(temp),
        preferences: preferences,
      );
      expect(await again.checkInBackground(), isNull);

      preferences.skippedVersion = null;
      preferences.autoCheck = false;
      expect(await again.checkInBackground(), isNull);
    });

    test('a failed background check stays silent', () async {
      final controller = AppUpdateController(
        currentVersion: '1.0.1',
        preferences: MemoryAppUpdatePreferences(),
        proxy: () => '',
        service: AppUpdateService(
          clientFactory: (_) => MockClient((_) async {
            throw const SocketException('offline');
          }),
        ),
        installer: _FakeInstaller(temp),
        periodicCheckInterval: Duration.zero,
      );
      expect(await controller.checkInBackground(), isNull);
      expect(controller.phase, AppUpdatePhase.idle);

      await controller.check();
      expect(controller.phase, AppUpdatePhase.failed);
      expect(controller.errorCode, 'network');
    });

    test('downloads, stages, and restarts; a cancelled exit cleans up',
        () async {
      final github = _FakeGitHub();
      final installer = _FakeInstaller(temp);
      final exits = <int>[];
      final controller = controllerFor(github, installer, exitRequests: exits);
      await controller.check();
      expect(controller.canInstallInApp, isTrue);

      await controller.downloadAndInstall();
      expect(controller.phase, AppUpdatePhase.readyToRestart);
      expect(installer.installed.single, endsWith('macOS-universal.dmg'));
      expect(github.packageDownloads, 1);

      expect(await controller.restartToUpdate(), isFalse);
      expect(installer.helperLaunches, 1);
      expect(exits, hasLength(1));
      expect(installer.cleanups, 1);
      expect(controller.phase, AppUpdatePhase.available);

      // The verified download is reused instead of fetched again.
      await controller.downloadAndInstall();
      expect(github.packageDownloads, 1);
      expect(controller.phase, AppUpdatePhase.readyToRestart);
      await controller.discardPreparedUpdate();
      expect(installer.cleanups, 2);
    });

    test('a corrupted download fails and retry downloads again', () async {
      final github = _FakeGitHub(packageBytes: utf8.encode('bad payload!!'));
      final installer = _FakeInstaller(temp);
      final controller = controllerFor(github, installer);
      await controller.check();
      await controller.downloadAndInstall();
      expect(controller.phase, AppUpdatePhase.failed);
      expect(controller.errorCode, 'checksum_mismatch');
      expect(installer.installed, isEmpty);

      github.packageBytes = null;
      await controller.retry();
      expect(controller.phase, AppUpdatePhase.readyToRestart);
      expect(github.packageDownloads, 2);
    });

    test('an up-to-date check clears leftover packages', () async {
      final leftover = File('${temp.path}/old.dmg')..writeAsStringSync('old');
      final github = _FakeGitHub(release: _releaseJson(tag: 'v1.01'));
      final installer = _FakeInstaller(temp);
      final controller = controllerFor(github, installer);
      await controller.check();
      expect(controller.phase, AppUpdatePhase.upToDate);
      await pumpEventQueue();
      expect(leftover.existsSync(), isFalse);
    });

    test('maps Android installer outcomes', () async {
      final controller = controllerFor(
        _FakeGitHub(),
        _FakeInstaller(temp, outcome: UpdateInstallOutcome.permissionRequired),
      );
      await controller.check();
      await controller.downloadAndInstall();
      expect(controller.phase, AppUpdatePhase.permissionRequired);
    });
  });

  group('AppUpdateInstaller', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('app-update-'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('locates the macOS bundle of the running executable', () {
      expect(
        AppUpdateInstaller.macAppBundleOf(
            '/Applications/NAI CasRand Forge.app/Contents/MacOS/NAI CasRand Forge'),
        '/Applications/NAI CasRand Forge.app',
      );
      expect(
          AppUpdateInstaller.macAppBundleOf('/usr/bin/flutter_tester'), isNull);
    });

    test('only desktop and Android platforms install in place', () {
      expect(AppUpdateInstaller(platform: TargetPlatform.macOS).packageKind,
          UpdatePackageKind.macosDmg);
      expect(AppUpdateInstaller(platform: TargetPlatform.windows).packageKind,
          UpdatePackageKind.windowsZip);
      expect(AppUpdateInstaller(platform: TargetPlatform.android).packageKind,
          UpdatePackageKind.androidApk);
      expect(
          AppUpdateInstaller(platform: TargetPlatform.iOS).packageKind, isNull);
      expect(AppUpdateInstaller(platform: TargetPlatform.linux).packageKind,
          isNull);
    });

    group('macOS', () {
      late String bundle;
      late List<List<String>> calls;
      late List<List<String>> started;
      String stagedVersion = '1.0.2';
      String stagedId = 'io.example.app';

      AppUpdateInstaller installer({String? executable}) {
        return AppUpdateInstaller(
          platform: TargetPlatform.macOS,
          resolvedExecutable:
              executable ?? '$bundle/Contents/MacOS/NAI CasRand Forge',
          currentPid: 4242,
          temporaryDirectory: () async => Directory('${temp.path}/tmp'),
          runProcess: (exe, args) async {
            calls.add([exe, ...args]);
            if (exe.endsWith('hdiutil') && args.first == 'attach') {
              final mount = args[args.indexOf('-mountpoint') + 1];
              Directory('$mount/NAI CasRand Forge.app').createSync();
              Link('$mount/Applications').createSync('/Applications');
            }
            if (exe.endsWith('ditto')) {
              Directory('${args[1]}/Contents').createSync(recursive: true);
            }
            if (exe.endsWith('PlistBuddy')) {
              final isStaged = args.last.contains('.update/');
              final key = args[1];
              final value = key.contains('Identifier')
                  ? (isStaged ? stagedId : 'io.example.app')
                  : (isStaged ? stagedVersion : '1.0.1');
              return ProcessResult(0, 0, '$value\n', '');
            }
            return ProcessResult(0, 0, '', '');
          },
          startDetached: (exe, args) async {
            started.add([exe, ...args]);
            return _FakeProcess();
          },
        );
      }

      setUp(() {
        bundle = '${temp.path}/Applications/NAI CasRand Forge.app';
        Directory('$bundle/Contents/MacOS').createSync(recursive: true);
        calls = [];
        started = [];
        stagedVersion = '1.0.2';
        stagedId = 'io.example.app';
      });

      test('stages the new bundle and launches the helper on demand', () async {
        final release = ReleaseInfo.fromGitHubJson(_releaseJson())!;
        final dmg = File('${temp.path}/update.dmg')..writeAsStringSync('dmg');
        final result = await installer().install(dmg, release);

        expect(result.outcome, UpdateInstallOutcome.restartRequired);
        final staging = Directory(
            '${temp.path}/Applications/.NAI CasRand Forge.app.update');
        expect(Directory('${staging.path}/NAI CasRand Forge.app').existsSync(),
            isTrue);
        expect(calls.map((c) => c.first.split('/').last),
            containsAllInOrder(['hdiutil', 'ditto', 'hdiutil', 'codesign']));
        expect(started, isEmpty);

        await result.launchHelper!();
        expect(started.single.first, '/bin/bash');
        expect(started.single.sublist(2, 5), [
          '4242',
          bundle,
          '${staging.path}/NAI CasRand Forge.app',
        ]);
        await result.cleanup!();
        expect(staging.existsSync(), isFalse);
      });

      test('rejects a package with the wrong version or identity', () async {
        final release = ReleaseInfo.fromGitHubJson(_releaseJson())!;
        final dmg = File('${temp.path}/update.dmg')..writeAsStringSync('dmg');
        stagedVersion = '1.0.1';
        await expectLater(
          installer().install(dmg, release),
          throwsA(isA<AppUpdateException>()
              .having((e) => e.code, 'code', 'install_failed')),
        );
        stagedVersion = '1.0.2';
        stagedId = 'io.other.app';
        await expectLater(
          installer().install(dmg, release),
          throwsA(isA<AppUpdateException>()),
        );
        expect(
          Directory('${temp.path}/Applications/.NAI CasRand Forge.app.update')
              .existsSync(),
          isFalse,
        );
      });

      test('opens the DMG when the app runs from a translocated copy',
          () async {
        final release = ReleaseInfo.fromGitHubJson(_releaseJson())!;
        final dmg = File('${temp.path}/update.dmg')..writeAsStringSync('dmg');
        final result = await installer(
          executable: '/private/var/folders/x/AppTranslocation/ABC/d/'
              'NAI CasRand Forge.app/Contents/MacOS/NAI CasRand Forge',
        ).install(dmg, release);
        expect(result.outcome, UpdateInstallOutcome.manualInstall);
        expect(calls.single, ['/usr/bin/open', dmg.path]);
      });
    });

    test('Android asks for install permission through the channel', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = AppUpdateInstaller.androidUpdateChannel;
      final requests = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        requests.add(call);
        return requests.length == 1 ? 'permission_required' : 'started';
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final installer = AppUpdateInstaller(platform: TargetPlatform.android);
      final release = ReleaseInfo.fromGitHubJson(_releaseJson())!;
      final apk = File('${temp.path}/update.apk');

      expect((await installer.install(apk, release)).outcome,
          UpdateInstallOutcome.permissionRequired);
      expect((await installer.install(apk, release)).outcome,
          UpdateInstallOutcome.installerOpened);
      expect(requests.first.method, 'installApk');
      expect(requests.first.arguments, {'path': apk.path});
    });
  });

  group('update UI', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('app-update-'));
    tearDown(() => temp.deleteSync(recursive: true));

    late Map<String, dynamic> translations;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/shared_preferences'),
        (call) async => call.method == 'getAll' ? <String, Object>{} : true,
      );
      await EasyLocalization.ensureInitialized();
      translations =
          json.decode(await rootBundle.loadString('assets/l10n/en.json'))
              as Map<String, dynamic>;
    });

    Future<void> pumpLocalized(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(EasyLocalization(
        key: UniqueKey(),
        supportedLocales: const [Locale('en')],
        path: 'test',
        assetLoader: _MapAssetLoader(translations),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        saveLocale: false,
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: Scaffold(body: child),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('settings tile announces an update and opens the dialog',
        (tester) async {
      final installer = _FakeInstaller(temp);
      final controller = AppUpdateController(
        currentVersion: '1.0.1',
        preferences: MemoryAppUpdatePreferences(),
        proxy: () => '',
        service: AppUpdateService(clientFactory: _FakeGitHub().client),
        installer: installer,
        periodicCheckInterval: Duration.zero,
      );
      await tester.runAsync(controller.check);
      await pumpLocalized(
          tester, AppUpdateSettingsTiles(controller: controller));

      expect(find.text('Version v1.02 is available — tap to view'),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('app-update-check-tile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-dialog')), findsOneWidget);
      expect(find.text('Version v1.02 is available'), findsOneWidget);
      expect(find.byKey(const Key('app-update-notes')), findsOneWidget);
      expect(find.byKey(const Key('app-update-install')), findsOneWidget);
      expect(find.byKey(const Key('app-update-skip')), findsNothing);

      await tester.runAsync(controller.downloadAndInstall);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-restart')), findsOneWidget);
    });

    testWidgets('automatic prompt offers skipping the version', (tester) async {
      final preferences = MemoryAppUpdatePreferences();
      final controller = AppUpdateController(
        currentVersion: '1.0.1',
        preferences: preferences,
        proxy: () => '',
        service: AppUpdateService(clientFactory: _FakeGitHub().client),
        installer: _FakeInstaller(temp),
        periodicCheckInterval: Duration.zero,
      );
      await tester.runAsync(controller.check);
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showAppUpdateDialog(context, controller, automatic: true),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('app-update-skip')));
      await tester.pumpAndSettle();
      expect(preferences.skippedVersion, 'v1.02');
      expect(find.byKey(const Key('app-update-dialog')), findsNothing);
    });

    testWidgets('auto-check switch persists the preference', (tester) async {
      final preferences = MemoryAppUpdatePreferences();
      final controller = AppUpdateController(
        currentVersion: '1.0.1',
        preferences: preferences,
        proxy: () => '',
        service: AppUpdateService(clientFactory: _FakeGitHub().client),
        installer: _FakeInstaller(temp),
        periodicCheckInterval: Duration.zero,
      );
      await pumpLocalized(
          tester, AppUpdateSettingsTiles(controller: controller));
      expect(find.text('Current version 1.0.1'), findsOneWidget);
      await tester.tap(find.byKey(const Key('app-update-auto-check')));
      await tester.pump();
      expect(preferences.autoCheck, isFalse);
    });
  });
}

class _FakeProcess implements Process {
  @override
  int get pid => 999999;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MapAssetLoader extends AssetLoader {
  const _MapAssetLoader(this.translations);

  final Map<String, dynamic> translations;

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async =>
      translations;
}
