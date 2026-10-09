import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Public repository that publishes CasRand Forge releases.
const appUpdateRepository = 'khkjdfkjhdsfakhds/CasRand-Forge';
const appUpdateReleasesUrl = 'https://github.com/$appUpdateRepository/releases';
const appUpdateLatestReleaseUrl = '$appUpdateReleasesUrl/latest';

/// Release version as published on GitHub.
///
/// Forge tags use two forms: `v0.9.8` (three parts) and `v1.01` (the second
/// part packs minor and patch digits, matching app version `1.0.1`).
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, {this.preRelease});

  final int major;
  final int minor;
  final int patch;

  /// Pre-release label such as `beta.5`; null for a final release.
  final String? preRelease;

  static AppVersion? tryParse(String raw) {
    var text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);
    final plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);
    String? preRelease;
    final dash = text.indexOf('-');
    if (dash >= 0) {
      preRelease = text.substring(dash + 1);
      text = text.substring(0, dash);
      if (preRelease.isEmpty) preRelease = null;
    }
    final segments = text.split('.');
    if (segments.isEmpty ||
        segments.length > 3 ||
        segments.any((s) => s.isEmpty || int.tryParse(s) == null)) {
      return null;
    }
    if (segments.length == 2 && segments[1].length == 2) {
      // `v1.01` -> 1.0.1, `v1.10` -> 1.1.0.
      return AppVersion(
        int.parse(segments[0]),
        int.parse(segments[1][0]),
        int.parse(segments[1][1]),
        preRelease: preRelease,
      );
    }
    final numbers = segments.map(int.parse).toList();
    while (numbers.length < 3) {
      numbers.add(0);
    }
    return AppVersion(numbers[0], numbers[1], numbers[2],
        preRelease: preRelease);
  }

  @override
  int compareTo(AppVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (pair.$1 != pair.$2) return pair.$1.compareTo(pair.$2);
    }
    if (preRelease == other.preRelease) return 0;
    if (preRelease == null) return 1;
    if (other.preRelease == null) return -1;
    return preRelease!.compareTo(other.preRelease!);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  @override
  String toString() =>
      '$major.$minor.$patch${preRelease == null ? '' : '-$preRelease'}';
}

/// Platform package that an in-app update can install.
enum UpdatePackageKind { macosDmg, windowsZip, androidApk }

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    this.size,
    this.sha256,
  });

  final String name;
  final Uri downloadUrl;
  final int? size;

  /// Lower-case hex digest published by GitHub, when available.
  final String? sha256;

  factory ReleaseAsset.fromGitHubJson(Map<String, dynamic> json) {
    final digest = json['digest'];
    String? sha;
    if (digest is String && digest.toLowerCase().startsWith('sha256:')) {
      sha = digest.substring('sha256:'.length).toLowerCase();
    }
    final size = json['size'];
    return ReleaseAsset(
      name: json['name'] as String,
      downloadUrl: Uri.parse(json['browser_download_url'] as String),
      size: size is int && size > 0 ? size : null,
      sha256: sha != null && _isSha256(sha) ? sha : null,
    );
  }
}

class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.version,
    required this.name,
    required this.notes,
    required this.pageUrl,
    required this.assets,
    this.publishedAt,
  });

  final String tagName;
  final AppVersion version;
  final String name;

  /// Release notes in Markdown; empty when only the tag could be resolved.
  final String notes;
  final Uri pageUrl;
  final List<ReleaseAsset> assets;
  final DateTime? publishedAt;

  /// Picks the package for [kind] using the Forge asset naming convention.
  ReleaseAsset? assetFor(UpdatePackageKind kind) {
    bool matches(ReleaseAsset asset) {
      final name = asset.name.toLowerCase();
      return switch (kind) {
        UpdatePackageKind.macosDmg => name.endsWith('.dmg'),
        UpdatePackageKind.windowsZip =>
          name.endsWith('.zip') && name.contains('windows'),
        UpdatePackageKind.androidApk => name.endsWith('.apk'),
      };
    }

    for (final asset in assets) {
      if (matches(asset)) return asset;
    }
    return null;
  }

  ReleaseAsset? get checksumAsset {
    for (final asset in assets) {
      if (asset.name.toUpperCase() == 'SHA256SUMS.TXT') return asset;
    }
    return null;
  }

  static ReleaseInfo? fromGitHubJson(Map<String, dynamic> json) {
    if (json['draft'] == true || json['prerelease'] == true) return null;
    final tag = json['tag_name'];
    if (tag is! String) return null;
    final version = AppVersion.tryParse(tag);
    if (version == null) return null;
    final assets = <ReleaseAsset>[];
    final rawAssets = json['assets'];
    if (rawAssets is List) {
      for (final raw in rawAssets) {
        if (raw is! Map<String, dynamic>) continue;
        if (raw['name'] is! String || raw['browser_download_url'] is! String) {
          continue;
        }
        assets.add(ReleaseAsset.fromGitHubJson(raw));
      }
    }
    final htmlUrl = json['html_url'];
    final name = json['name'];
    final body = json['body'];
    return ReleaseInfo(
      tagName: tag,
      version: version,
      name: name is String && name.trim().isNotEmpty ? name.trim() : tag,
      notes: body is String ? body.trim() : '',
      pageUrl: Uri.parse(htmlUrl is String
          ? htmlUrl
          : '$appUpdateReleasesUrl/tag/${Uri.encodeComponent(tag)}'),
      assets: assets,
      publishedAt: DateTime.tryParse(json['published_at']?.toString() ?? ''),
    );
  }

  /// Release reconstructed from a tag alone, used when the GitHub REST API is
  /// unavailable (for example rate limited). Asset names follow the CI
  /// workflows; checksums then come from `SHA256SUMS.txt`.
  static ReleaseInfo? fromTag(String tag) {
    final version = AppVersion.tryParse(tag);
    if (version == null || version.preRelease != null) return null;
    Uri download(String name) => Uri.parse(
        '$appUpdateReleasesUrl/download/${Uri.encodeComponent(tag)}/$name');
    ReleaseAsset asset(String name) =>
        ReleaseAsset(name: name, downloadUrl: download(name));
    return ReleaseInfo(
      tagName: tag,
      version: version,
      name: 'CasRand Forge $tag',
      notes: '',
      pageUrl:
          Uri.parse('$appUpdateReleasesUrl/tag/${Uri.encodeComponent(tag)}'),
      assets: [
        asset('NAI-CasRand-Forge-$tag-macOS-universal.dmg'),
        asset('NAI-CasRand-Forge-$tag-Windows-x64.zip'),
        asset('NAI-CasRand-Forge-$tag-Android.apk'),
        asset('SHA256SUMS.txt'),
      ],
    );
  }
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.latest,
  });

  final AppVersion currentVersion;
  final ReleaseInfo latest;

  bool get hasUpdate => latest.version > currentVersion;
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.code, [this.detail]);

  /// Stable code used for localization: `network`, `no_release`,
  /// `bad_version`, `no_package`, `no_checksum`, `checksum_mismatch`,
  /// `cancelled`, `install_failed`.
  final String code;
  final String? detail;

  @override
  String toString() =>
      'AppUpdateException($code${detail == null ? '' : ': $detail'})';
}

class UpdateDownloadCancelled extends AppUpdateException {
  const UpdateDownloadCancelled() : super('cancelled');
}

/// Cancellation handle for a running download.
class UpdateCancelToken {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void _onCancel(void Function() listener) => _listeners.add(listener);
}

typedef UpdateDownloadProgress = void Function(int received, int? total);

/// Queries GitHub Releases and downloads verified update packages.
class AppUpdateService {
  AppUpdateService({
    http.Client Function(String proxy)? clientFactory,
    Duration requestTimeout = const Duration(seconds: 20),
  })  : _clientFactory = clientFactory ?? _defaultClient,
        _requestTimeout = requestTimeout;

  final http.Client Function(String proxy) _clientFactory;
  final Duration _requestTimeout;

  static http.Client _defaultClient(String proxy) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);
    final trimmed = proxy.trim();
    if (trimmed.isNotEmpty) {
      client.findProxy = (_) => 'PROXY $trimmed';
    }
    return IOClient(client);
  }

  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'CasRand-Forge-Updater',
  };

  /// Returns the latest final release compared with [currentVersion].
  Future<UpdateCheckResult> checkForUpdate({
    required String currentVersion,
    String proxy = '',
  }) async {
    final current = AppVersion.tryParse(currentVersion);
    if (current == null) {
      throw AppUpdateException('bad_version', currentVersion);
    }
    final client = _clientFactory(proxy);
    try {
      final release = await _fetchLatestFromApi(client) ??
          await _fetchLatestFromRedirect(client);
      if (release == null) throw const AppUpdateException('no_release');
      return UpdateCheckResult(currentVersion: current, latest: release);
    } on AppUpdateException {
      rethrow;
    } on TimeoutException catch (error) {
      throw AppUpdateException('network', error.toString());
    } on Exception catch (error) {
      throw AppUpdateException('network', error.toString());
    } finally {
      client.close();
    }
  }

  Future<ReleaseInfo?> _fetchLatestFromApi(http.Client client) async {
    try {
      final response = await client
          .get(
            Uri.parse(
                'https://api.github.com/repos/$appUpdateRepository/releases/latest'),
            headers: _headers,
          )
          .timeout(_requestTimeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) return null;
      return ReleaseInfo.fromGitHubJson(decoded);
    } on FormatException {
      return null;
    } on Exception {
      // Rate limits and API outages fall through to the web redirect.
      return null;
    }
  }

  Future<ReleaseInfo?> _fetchLatestFromRedirect(http.Client client) async {
    final request = http.Request('GET', Uri.parse(appUpdateLatestReleaseUrl))
      ..followRedirects = false
      ..headers['User-Agent'] = _headers['User-Agent']!;
    final response = await client.send(request).timeout(_requestTimeout);
    unawaited(response.stream.drain<void>().catchError((_) {}));
    final location = response.headers['location'];
    if (location == null) {
      throw AppUpdateException('network', 'HTTP ${response.statusCode}');
    }
    final segments = Uri.parse(location).pathSegments;
    final tagIndex = segments.indexOf('tag');
    if (tagIndex < 0 || tagIndex + 1 >= segments.length) {
      throw const AppUpdateException('no_release');
    }
    return ReleaseInfo.fromTag(segments[tagIndex + 1]);
  }

  /// Resolves the expected SHA-256 for [asset], using the GitHub digest first
  /// and `SHA256SUMS.txt` second.
  Future<String> resolveChecksum({
    required ReleaseInfo release,
    required ReleaseAsset asset,
    String proxy = '',
  }) async {
    if (asset.sha256 != null) return asset.sha256!;
    final sums = release.checksumAsset;
    if (sums == null) throw const AppUpdateException('no_checksum');
    final client = _clientFactory(proxy);
    try {
      final response = await client.get(sums.downloadUrl, headers: {
        'User-Agent': _headers['User-Agent']!,
      }).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        throw AppUpdateException('no_checksum', 'HTTP ${response.statusCode}');
      }
      final sha = parseChecksumFile(response.body, asset.name);
      if (sha == null) throw const AppUpdateException('no_checksum');
      return sha;
    } on AppUpdateException {
      rethrow;
    } on Exception catch (error) {
      throw AppUpdateException('network', error.toString());
    } finally {
      client.close();
    }
  }

  /// True when [file] already holds a package with [expectedSha256], so an
  /// earlier download can be reused. Hashing runs off the UI isolate.
  static Future<bool> fileMatchesChecksum(
      File file, String expectedSha256) async {
    if (!await file.exists()) return false;
    final path = file.path;
    try {
      final actual = await Isolate.run(() async {
        final digest = await sha256.bind(File(path).openRead()).first;
        return digest.toString();
      });
      return actual == expectedSha256.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  /// Parses `sha256sum` output (`<hex>  <name>` or `<hex> *<name>`).
  static String? parseChecksumFile(String content, String fileName) {
    for (final line in const LineSplitter().convert(content)) {
      final match =
          RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$').firstMatch(line.trim());
      if (match != null && match.group(2) == fileName) {
        return match.group(1)!.toLowerCase();
      }
    }
    return null;
  }

  /// Streams [asset] into [destination], hashing while writing so a 30 MB
  /// package never needs a second blocking pass. The file only appears at
  /// [destination] after its SHA-256 matches [expectedSha256].
  Future<File> download({
    required ReleaseAsset asset,
    required String expectedSha256,
    required File destination,
    String proxy = '',
    UpdateDownloadProgress? onProgress,
    UpdateCancelToken? cancelToken,
  }) async {
    final partial = File('${destination.path}.part');
    await destination.parent.create(recursive: true);
    if (await partial.exists()) await partial.delete();
    final client = _clientFactory(proxy);
    cancelToken?._onCancel(client.close);
    IOSink? sink;
    try {
      final request = http.Request('GET', asset.downloadUrl)
        ..headers['User-Agent'] = _headers['User-Agent']!;
      final response = await client.send(request).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        throw AppUpdateException('network', 'HTTP ${response.statusCode}');
      }
      final total = response.contentLength ?? asset.size;
      final digestSink = _DigestSink();
      final hasher = sha256.startChunkedConversion(digestSink);
      sink = partial.openWrite();
      var received = 0;
      onProgress?.call(0, total);
      await for (final chunk in response.stream) {
        if (cancelToken?.isCancelled ?? false) {
          throw const UpdateDownloadCancelled();
        }
        hasher.add(chunk);
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      hasher.close();
      await sink.flush();
      await sink.close();
      sink = null;
      if (cancelToken?.isCancelled ?? false) {
        throw const UpdateDownloadCancelled();
      }
      final actual = digestSink.value.toString();
      if (actual != expectedSha256.toLowerCase()) {
        throw AppUpdateException('checksum_mismatch', actual);
      }
      if (await destination.exists()) await destination.delete();
      return await partial.rename(destination.path);
    } on AppUpdateException {
      rethrow;
    } on Exception catch (error) {
      if (cancelToken?.isCancelled ?? false) {
        throw const UpdateDownloadCancelled();
      }
      throw AppUpdateException('network', error.toString());
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
      if (await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
