import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:nai_casrand/data/services/app_update_installer.dart';
import 'package:nai_casrand/data/services/app_update_service.dart';

/// Device-local update preferences. They are kept out of the exported
/// configuration JSON because they describe this installation, not a setup.
abstract class AppUpdatePreferences {
  bool get autoCheck;
  set autoCheck(bool value);
  String? get skippedVersion;
  set skippedVersion(String? value);
}

class HiveAppUpdatePreferences implements AppUpdatePreferences {
  HiveAppUpdatePreferences(this._box);

  final Box _box;

  static const _autoCheckKey = 'app_update_auto_check';
  static const _skippedVersionKey = 'app_update_skipped_version';

  @override
  bool get autoCheck =>
      _box.get(_autoCheckKey) is bool ? _box.get(_autoCheckKey) as bool : true;

  @override
  set autoCheck(bool value) => unawaited(_box.put(_autoCheckKey, value));

  @override
  String? get skippedVersion {
    final value = _box.get(_skippedVersionKey);
    return value is String && value.isNotEmpty ? value : null;
  }

  @override
  set skippedVersion(String? value) => unawaited(value == null
      ? _box.delete(_skippedVersionKey)
      : _box.put(_skippedVersionKey, value));
}

class MemoryAppUpdatePreferences implements AppUpdatePreferences {
  MemoryAppUpdatePreferences({this.autoCheck = true, this.skippedVersion});

  @override
  bool autoCheck;

  @override
  String? skippedVersion;
}

enum AppUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  preparing,
  readyToRestart,
  installerOpened,
  permissionRequired,
  manualInstall,
  failed,
}

/// Owns the update lifecycle: checking, downloading, staging and restarting.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required this.currentVersion,
    required this.preferences,
    required String Function() proxy,
    AppUpdateService? service,
    AppUpdateInstaller? installer,
    Future<AppExitResponse> Function()? requestExit,
    this.periodicCheckInterval = const Duration(hours: 12),
  })  : _proxy = proxy,
        service = service ?? AppUpdateService(),
        installer = installer ?? AppUpdateInstaller(),
        _requestExit = requestExit ??
            (() => ServicesBinding.instance
                .exitApplication(AppExitType.cancelable));

  final String currentVersion;
  final AppUpdatePreferences preferences;
  final AppUpdateService service;
  final AppUpdateInstaller installer;
  final String Function() _proxy;
  final Future<AppExitResponse> Function() _requestExit;
  final Duration periodicCheckInterval;

  AppUpdatePhase _phase = AppUpdatePhase.idle;
  UpdateCheckResult? _result;
  String? _errorCode;
  bool _failedDuringInstall = false;
  int _received = 0;
  int? _total;
  DateTime? _lastCheckedAt;
  UpdateCancelToken? _cancelToken;
  UpdateInstallResult? _prepared;
  Timer? _periodicTimer;
  final Set<String> _promptedVersions = {};

  AppUpdatePhase get phase => _phase;
  UpdateCheckResult? get result => _result;
  ReleaseInfo? get latestRelease => _result?.latest;
  String? get errorCode => _errorCode;
  int get receivedBytes => _received;
  int? get totalBytes => _total;
  DateTime? get lastCheckedAt => _lastCheckedAt;

  bool get autoCheckEnabled => preferences.autoCheck;
  bool get updateAvailable => _result?.hasUpdate ?? false;

  bool get isBusy =>
      _phase == AppUpdatePhase.checking ||
      _phase == AppUpdatePhase.downloading ||
      _phase == AppUpdatePhase.preparing;

  /// Package for this platform in the latest release, when installable here.
  ReleaseAsset? get installableAsset {
    final kind = installer.packageKind;
    final release = latestRelease;
    if (kind == null || release == null) return null;
    return release.assetFor(kind);
  }

  bool get canInstallInApp => updateAvailable && installableAsset != null;

  bool get restartIsAutomatic =>
      installer.packageKind == UpdatePackageKind.macosDmg ||
      installer.packageKind == UpdatePackageKind.windowsZip;

  void setAutoCheckEnabled(bool value) {
    preferences.autoCheck = value;
    if (value) {
      _schedulePeriodicChecks();
    } else {
      _periodicTimer?.cancel();
      _periodicTimer = null;
    }
    notifyListeners();
  }

  /// Checks GitHub. Errors become [AppUpdatePhase.failed] with [errorCode].
  Future<UpdateCheckResult?> check() async {
    if (isBusy || _phase == AppUpdatePhase.readyToRestart) return _result;
    _failedDuringInstall = false;
    _setPhase(AppUpdatePhase.checking);
    try {
      final result = await service.checkForUpdate(
        currentVersion: currentVersion,
        proxy: _proxy(),
      );
      _result = result;
      _lastCheckedAt = DateTime.now();
      if (!result.hasUpdate) {
        // Packages from an update that has since been applied are obsolete.
        unawaited(installer.clearWorkingDirectory());
      }
      _errorCode = null;
      _setPhase(result.hasUpdate
          ? AppUpdatePhase.available
          : AppUpdatePhase.upToDate);
      return result;
    } on AppUpdateException catch (error) {
      _fail(error.code);
      return null;
    }
  }

  /// Background check that decides whether to interrupt the user. Returns the
  /// release to announce, or null when there is nothing new to show.
  Future<ReleaseInfo?> checkInBackground() async {
    if (kIsWeb || !preferences.autoCheck) return null;
    _schedulePeriodicChecks();
    if (isBusy || _phase == AppUpdatePhase.readyToRestart) return null;
    final previousPhase = _phase;
    final previousError = _errorCode;
    final result = await check();
    if (result == null) {
      // A silent check must not leave the settings page showing an error.
      _errorCode = previousError;
      _setPhase(previousPhase == AppUpdatePhase.failed
          ? AppUpdatePhase.idle
          : previousPhase);
      return null;
    }
    if (!result.hasUpdate) return null;
    final tag = result.latest.tagName;
    if (preferences.skippedVersion == tag) return null;
    if (!_promptedVersions.add(tag)) return null;
    return result.latest;
  }

  /// Called by the periodic timer; the UI layer supplies the prompt.
  void Function(ReleaseInfo release)? onBackgroundUpdateFound;

  void _schedulePeriodicChecks() {
    if (_periodicTimer != null || periodicCheckInterval <= Duration.zero) {
      return;
    }
    _periodicTimer = Timer.periodic(periodicCheckInterval, (_) async {
      final release = await checkInBackground();
      if (release != null) onBackgroundUpdateFound?.call(release);
    });
  }

  void skipLatestVersion() {
    final tag = latestRelease?.tagName;
    if (tag == null) return;
    preferences.skippedVersion = tag;
    notifyListeners();
  }

  /// Downloads (or reuses) the verified package and stages it.
  Future<void> downloadAndInstall() async {
    final release = latestRelease;
    final asset = installableAsset;
    if (release == null || asset == null || isBusy) return;
    _received = 0;
    _total = asset.size;
    _errorCode = null;
    _failedDuringInstall = true;
    _setPhase(AppUpdatePhase.downloading);
    final token = UpdateCancelToken();
    _cancelToken = token;
    try {
      final proxy = _proxy();
      final sha = await service.resolveChecksum(
          release: release, asset: asset, proxy: proxy);
      if (token.isCancelled) throw const UpdateDownloadCancelled();
      final dir = await installer.workingDirectory();
      final package = File('${dir.path}${Platform.pathSeparator}${asset.name}');
      if (!await AppUpdateService.fileMatchesChecksum(package, sha)) {
        await _discardOtherDownloads(dir, asset.name);
        await service.download(
          asset: asset,
          expectedSha256: sha,
          destination: package,
          proxy: proxy,
          cancelToken: token,
          onProgress: (received, total) {
            _received = received;
            _total = total;
            notifyListeners();
          },
        );
      } else {
        _received = await package.length();
        _total = _received;
      }
      if (token.isCancelled) throw const UpdateDownloadCancelled();
      _setPhase(AppUpdatePhase.preparing);
      final prepared = await installer.install(package, release);
      _prepared = prepared;
      _setPhase(switch (prepared.outcome) {
        UpdateInstallOutcome.restartRequired => AppUpdatePhase.readyToRestart,
        UpdateInstallOutcome.installerOpened => AppUpdatePhase.installerOpened,
        UpdateInstallOutcome.permissionRequired =>
          AppUpdatePhase.permissionRequired,
        UpdateInstallOutcome.manualInstall => AppUpdatePhase.manualInstall,
      });
    } on UpdateDownloadCancelled {
      _received = 0;
      _setPhase(AppUpdatePhase.available);
    } on AppUpdateException catch (error) {
      _fail(error.code);
    } catch (error) {
      debugPrint('App update failed: $error');
      _fail('install_failed');
    } finally {
      if (identical(_cancelToken, token)) _cancelToken = null;
    }
  }

  Future<void> _discardOtherDownloads(Directory dir, String keep) async {
    try {
      await for (final entry in dir.list()) {
        final name = entry.uri.pathSegments
            .lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (entry is File && name != keep) {
          await entry.delete();
        }
      }
    } catch (_) {}
  }

  /// Repeats whichever step failed last.
  Future<void> retry() async {
    if (_failedDuringInstall && updateAvailable) {
      await downloadAndInstall();
    } else {
      await check();
    }
  }

  void cancelDownload() => _cancelToken?.cancel();

  /// Starts the helper and quits through the normal exit path, which still
  /// waits for pending image writes. A cancelled exit discards the staging.
  Future<bool> restartToUpdate() async {
    final prepared = _prepared;
    if (_phase != AppUpdatePhase.readyToRestart ||
        prepared?.launchHelper == null) {
      return false;
    }
    try {
      await prepared!.launchHelper!();
    } catch (error) {
      debugPrint('Update helper failed to start: $error');
      await prepared!.cleanup?.call();
      _prepared = null;
      _fail('install_failed');
      return false;
    }
    final response = await _requestExit();
    if (response == AppExitResponse.exit) {
      // Platforms that do not terminate on their own still need to quit for
      // the helper to proceed; storage was drained by the exit observers.
      exit(0);
    }
    await prepared.cleanup?.call();
    _prepared = null;
    _setPhase(AppUpdatePhase.available);
    return false;
  }

  /// Leaves a staged update unapplied; the verified download stays cached.
  Future<void> discardPreparedUpdate() async {
    final prepared = _prepared;
    _prepared = null;
    await prepared?.cleanup?.call();
    if (_phase == AppUpdatePhase.readyToRestart ||
        _phase == AppUpdatePhase.manualInstall ||
        _phase == AppUpdatePhase.installerOpened ||
        _phase == AppUpdatePhase.permissionRequired) {
      _setPhase(AppUpdatePhase.available);
    }
  }

  void _fail(String code) {
    _errorCode = code;
    _setPhase(AppUpdatePhase.failed);
  }

  void _setPhase(AppUpdatePhase phase) {
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    _periodicTimer?.cancel();
    _cancelToken?.cancel();
    super.dispose();
  }
}
