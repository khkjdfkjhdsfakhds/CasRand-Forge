import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/data/services/app_update_service.dart';
import 'package:path_provider/path_provider.dart';

/// How an installer finished handing the update over.
enum UpdateInstallOutcome {
  /// A helper waits for this process to exit, swaps the files, and relaunches.
  restartRequired,

  /// The system package installer is showing the update (Android).
  installerOpened,

  /// Android must first allow this app to install unknown apps; the settings
  /// page has been opened and the user can retry afterwards.
  permissionRequired,

  /// The package could not be applied in place (read-only location,
  /// translocated app, …); it has been revealed for manual installation.
  manualInstall,
}

class UpdateInstallResult {
  const UpdateInstallResult(this.outcome, {this.launchHelper, this.cleanup});

  final UpdateInstallOutcome outcome;

  /// Starts the detached helper for [UpdateInstallOutcome.restartRequired];
  /// the app must then exit so the helper can apply the staged files.
  final Future<void> Function()? launchHelper;

  /// Stops a started helper and discards staged files when the app ends up
  /// not restarting.
  final Future<void> Function()? cleanup;
}

typedef UpdateProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);
typedef UpdateProcessStarter = Future<Process> Function(
    String executable, List<String> arguments);

/// Applies a verified update package on the current platform.
class AppUpdateInstaller {
  AppUpdateInstaller({
    TargetPlatform? platform,
    String? resolvedExecutable,
    int? currentPid,
    UpdateProcessRunner? runProcess,
    UpdateProcessStarter? startDetached,
    Future<Directory> Function()? temporaryDirectory,
    MethodChannel? androidChannel,
  })  : _platform = platform ?? (kIsWeb ? null : defaultTargetPlatform),
        _resolvedExecutable = resolvedExecutable,
        _currentPid = currentPid,
        _runProcess = runProcess ?? Process.run,
        _startDetached = startDetached ??
            ((exe, args) =>
                Process.start(exe, args, mode: ProcessStartMode.detached)),
        _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
        _androidChannel = androidChannel ?? androidUpdateChannel;

  static const androidUpdateChannel =
      MethodChannel('io.github.khkjdfkjhdsfakhds.casrandforge/app_update');

  final TargetPlatform? _platform;
  final String? _resolvedExecutable;
  final int? _currentPid;
  final UpdateProcessRunner _runProcess;
  final UpdateProcessStarter _startDetached;
  final Future<Directory> Function() _temporaryDirectory;
  final MethodChannel _androidChannel;

  String get _executable => _resolvedExecutable ?? Platform.resolvedExecutable;
  int get _pid => _currentPid ?? pid;

  /// Package this platform installs in place, or null to use the release page.
  UpdatePackageKind? get packageKind => switch (_platform) {
        TargetPlatform.macOS => UpdatePackageKind.macosDmg,
        TargetPlatform.windows => UpdatePackageKind.windowsZip,
        TargetPlatform.android => UpdatePackageKind.androidApk,
        _ => null,
      };

  /// Directory that holds downloads and staging data for [release].
  Future<Directory> workingDirectory() async {
    final temp = await _temporaryDirectory();
    // Android's FileProvider-equivalent only exposes `cache/updates/`.
    final dir = Directory('${temp.path}${Platform.pathSeparator}'
        '${_platform == TargetPlatform.android ? 'updates' : 'casrand-forge-update'}');
    await dir.create(recursive: true);
    return dir;
  }

  /// Removes downloads from earlier update attempts.
  Future<void> clearWorkingDirectory() async {
    try {
      final dir = await workingDirectory();
      await for (final entry in dir.list()) {
        try {
          await entry.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<UpdateInstallResult> install(File package, ReleaseInfo release) {
    return switch (_platform) {
      TargetPlatform.macOS => _installMacOS(package, release),
      TargetPlatform.windows => _installWindows(package),
      TargetPlatform.android => _installAndroid(package),
      _ => throw const AppUpdateException('no_package'),
    };
  }

  /// Opens the Android "install unknown apps" page for this app.
  Future<void> openAndroidInstallPermissionSettings() async {
    await _androidChannel.invokeMethod<void>('openInstallPermissionSettings');
  }

  // ---------------------------------------------------------------- macOS

  /// `/Applications/X.app/Contents/MacOS/X` -> `/Applications/X.app`.
  @visibleForTesting
  static String? macAppBundleOf(String executable) {
    final marker = executable.lastIndexOf('.app/Contents/MacOS/');
    if (marker < 0) return null;
    return executable.substring(0, marker + '.app'.length);
  }

  Future<UpdateInstallResult> _installMacOS(
      File dmg, ReleaseInfo release) async {
    final bundle = macAppBundleOf(_executable);
    if (bundle == null ||
        bundle.contains('/AppTranslocation/') ||
        bundle.startsWith('/Volumes/')) {
      return _revealMacPackage(dmg);
    }
    final parent = File(bundle).parent.path;
    final bundleName = bundle.substring(parent.length + 1);
    final staging = Directory('$parent/.$bundleName.update');
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create();
    } on FileSystemException {
      // No write access to the install folder (for example a standard user in
      // /Applications); let the user drag the new app in from the DMG.
      return _revealMacPackage(dmg);
    }

    final work = await workingDirectory();
    final mountPoint = Directory('${work.path}/mount');
    if (await mountPoint.exists()) {
      await _runProcess(
          '/usr/bin/hdiutil', ['detach', mountPoint.path, '-force']);
      try {
        await mountPoint.delete(recursive: true);
      } catch (_) {}
    }
    await mountPoint.create(recursive: true);
    final stagedApp = '${staging.path}/$bundleName';
    try {
      await _checked('/usr/bin/hdiutil', [
        'attach',
        dmg.path,
        '-nobrowse',
        '-noautoopen',
        '-readonly',
        '-mountpoint',
        mountPoint.path,
      ]);
      try {
        final source = await _findMacApp(mountPoint);
        if (source == null) {
          throw const AppUpdateException('install_failed', 'no .app in DMG');
        }
        await _checked('/usr/bin/ditto', [source, stagedApp]);
      } finally {
        await _runProcess(
            '/usr/bin/hdiutil', ['detach', mountPoint.path, '-force']);
      }

      final currentId = await _plistValue(bundle, 'CFBundleIdentifier');
      final stagedId = await _plistValue(stagedApp, 'CFBundleIdentifier');
      if (currentId != null && stagedId != currentId) {
        throw AppUpdateException('install_failed', 'bundle id $stagedId');
      }
      final stagedVersion = AppVersion.tryParse(
          await _plistValue(stagedApp, 'CFBundleShortVersionString') ?? '');
      if (stagedVersion == null || stagedVersion != release.version) {
        throw AppUpdateException('install_failed', 'version $stagedVersion');
      }
      await _checked(
          '/usr/bin/codesign', ['--verify', '--deep', '--strict', stagedApp]);
      await _runProcess(
          '/usr/bin/xattr', ['-dr', 'com.apple.quarantine', stagedApp]);

      final script = File('${work.path}/apply-update.sh');
      await script.writeAsString(_macHelperScript);
      Process? helper;
      return UpdateInstallResult(
        UpdateInstallOutcome.restartRequired,
        launchHelper: () async {
          helper = await _startDetached('/bin/bash', [
            script.path,
            '$_pid',
            bundle,
            stagedApp,
            '${work.path}/apply-update.log',
          ]);
        },
        cleanup: () async {
          final started = helper;
          if (started != null) Process.killPid(started.pid);
          try {
            await staging.delete(recursive: true);
          } catch (_) {}
        },
      );
    } catch (error) {
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
      if (error is AppUpdateException) rethrow;
      throw AppUpdateException('install_failed', error.toString());
    }
  }

  Future<String?> _findMacApp(Directory mountPoint) async {
    await for (final entry in mountPoint.list(followLinks: false)) {
      if (entry is Directory && entry.path.endsWith('.app')) return entry.path;
    }
    return null;
  }

  Future<String?> _plistValue(String app, String key) async {
    final result = await _runProcess('/usr/libexec/PlistBuddy',
        ['-c', 'Print :$key', '$app/Contents/Info.plist']);
    if (result.exitCode != 0) return null;
    return result.stdout.toString().trim();
  }

  Future<UpdateInstallResult> _revealMacPackage(File dmg) async {
    await _runProcess('/usr/bin/open', [dmg.path]);
    return const UpdateInstallResult(UpdateInstallOutcome.manualInstall);
  }

  /// Waits for the app to quit, swaps the bundle with a rollback, relaunches.
  static const _macHelperScript = r'''#!/bin/bash
APP_PID="$1"; TARGET="$2"; STAGED="$3"; LOG="$4"
exec >>"$LOG" 2>&1
echo "[$(date)] waiting for $APP_PID"
for _ in $(seq 1 1200); do
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 0.5
done
STAGING_DIR="$(dirname "$STAGED")"
if kill -0 "$APP_PID" 2>/dev/null; then
  echo "app did not exit; update abandoned"
  rm -rf "$STAGING_DIR"
  exit 1
fi
BACKUP="$STAGING_DIR/previous.app"
if mv "$TARGET" "$BACKUP"; then
  if mv "$STAGED" "$TARGET"; then
    echo "update applied"
  else
    echo "swap failed; restoring"
    mv "$BACKUP" "$TARGET"
  fi
else
  echo "could not move current app"
fi
rm -rf "$STAGING_DIR"
# Only relaunch a complete bundle: for a broken path, `open` would let Launch
# Services start some other copy that shares the bundle identifier.
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TARGET/Contents/Info.plist" 2>/dev/null)"
if [ -n "$EXE" ] && [ -x "$TARGET/Contents/MacOS/$EXE" ]; then
  open "$TARGET"
else
  echo "target is not launchable; not reopening"
fi
''';

  // -------------------------------------------------------------- Windows

  Future<UpdateInstallResult> _installWindows(File zip) async {
    final exe = File(_executable);
    final installDir = exe.parent;
    final exeName = exe.uri.pathSegments.last;
    final probe = File('${installDir.path}\\.casrand-update-probe');
    try {
      await probe.writeAsString('');
      await probe.delete();
    } on FileSystemException {
      await _runProcess('explorer.exe', ['/select,', zip.path]);
      return const UpdateInstallResult(UpdateInstallOutcome.manualInstall);
    }

    final work = await workingDirectory();
    final staged = Directory('${work.path}\\app');
    if (await staged.exists()) await staged.delete(recursive: true);
    try {
      final zipPath = zip.path;
      final stagedPath = staged.path;
      await Isolate.run(() => extractFileToDisk(zipPath, stagedPath));
    } catch (error) {
      throw AppUpdateException('install_failed', error.toString());
    }
    if (!await File('${staged.path}\\$exeName').exists()) {
      throw AppUpdateException('install_failed', '$exeName missing');
    }

    final script = File('${work.path}\\apply-update.ps1');
    await script.writeAsString(_windowsHelperScript);
    Process? helper;
    return UpdateInstallResult(
      UpdateInstallOutcome.restartRequired,
      launchHelper: () async {
        helper = await _startDetached('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          script.path,
          '-AppPid',
          '$_pid',
          '-Source',
          staged.path,
          '-Target',
          installDir.path,
          '-Exe',
          exeName,
          '-Log',
          '${work.path}\\apply-update.log',
        ]);
      },
      cleanup: () async {
        final started = helper;
        if (started != null) Process.killPid(started.pid);
        try {
          await staged.delete(recursive: true);
        } catch (_) {}
      },
    );
  }

  /// Waits for the app to quit, copies the new files over the install folder
  /// (user data lives elsewhere), and relaunches.
  static const _windowsHelperScript = r'''param(
  [int]$AppPid,
  [string]$Source,
  [string]$Target,
  [string]$Exe,
  [string]$Log
)
"[$(Get-Date)] waiting for $AppPid" | Out-File -Append -Encoding utf8 $Log
try { Wait-Process -Id $AppPid -Timeout 600 -ErrorAction SilentlyContinue } catch {}
if (Get-Process -Id $AppPid -ErrorAction SilentlyContinue) {
  "app did not exit; update abandoned" | Out-File -Append -Encoding utf8 $Log
  exit 1
}
Start-Sleep -Milliseconds 500
$code = 0
for ($i = 0; $i -lt 5; $i++) {
  robocopy $Source $Target /E /R:5 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
  $code = $LASTEXITCODE
  if ($code -lt 8) { break }
  Start-Sleep -Seconds 2
}
"robocopy exit $code" | Out-File -Append -Encoding utf8 $Log
if ($code -lt 8) {
  Remove-Item -Recurse -Force $Source -ErrorAction SilentlyContinue
}
Start-Process -FilePath (Join-Path $Target $Exe) -WorkingDirectory $Target
''';

  // -------------------------------------------------------------- Android

  Future<UpdateInstallResult> _installAndroid(File apk) async {
    final String? status;
    try {
      status = await _androidChannel
          .invokeMethod<String>('installApk', {'path': apk.path});
    } on PlatformException catch (error) {
      throw AppUpdateException('install_failed', error.message ?? error.code);
    } on MissingPluginException {
      throw const AppUpdateException('install_failed', 'channel missing');
    }
    if (status == 'permission_required') {
      return const UpdateInstallResult(UpdateInstallOutcome.permissionRequired);
    }
    return const UpdateInstallResult(UpdateInstallOutcome.installerOpened);
  }

  // --------------------------------------------------------------- shared

  Future<void> _checked(String executable, List<String> arguments) async {
    final result = await _runProcess(executable, arguments);
    if (result.exitCode != 0) {
      throw AppUpdateException('install_failed',
          '${executable.split('/').last} ${result.exitCode}: ${result.stderr}');
    }
  }
}
