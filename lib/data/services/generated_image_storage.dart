import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/services/generated_image_jpeg_encoder.dart';
import 'package:path_provider/path_provider.dart';

enum GeneratedImageStorageStatus {
  queued,
  savingSessionPng,
  encoding,
  publishing,
  jpegSaved,
  pngFallbackSaved,
  skippedNotSmaller,
  saving,
  saved,
  failed,
  abandoned,
}

class GeneratedImageFile {
  final String path;
  final String mediaType;
  final bool isPermanent;

  const GeneratedImageFile({
    required this.path,
    required this.mediaType,
    required this.isPermanent,
  });
}

/// Raised when a storage operation is stopped by the orderly shutdown flow.
///
/// This is deliberately a distinct error so generation scheduling can tell a
/// user-selected abandon apart from a disk or encoder failure.
class GeneratedImageStorageAbandonedException implements Exception {
  final String message;

  const GeneratedImageStorageAbandonedException([
    this.message = 'Generated-image storage was abandoned during shutdown.',
  ]);

  @override
  String toString() => 'GeneratedImageStorageAbandonedException: $message';
}

/// Caller-facing state for one generated image throughout its storage life.
///
/// The preview bytes are available synchronously. File-backed actions use
/// [currentFile], while [permanentFiles] describes durable published outputs.
class GeneratedImageArtifact extends ChangeNotifier {
  final Uint8List previewBytes;

  GeneratedImageStorageStatus _status;
  GeneratedImageFile? _currentFile;
  GeneratedImageFile? _originalPngFile;
  List<GeneratedImageFile> _permanentFiles;
  Object? _failure;

  GeneratedImageArtifact._({
    required this.previewBytes,
    GeneratedImageStorageStatus status = GeneratedImageStorageStatus.saving,
  })  : _status = status,
        _permanentFiles = const [];

  GeneratedImageStorageStatus get status => _status;
  GeneratedImageFile? get currentFile => _currentFile;
  GeneratedImageFile? get originalPngFile => _originalPngFile;
  List<GeneratedImageFile> get permanentFiles =>
      List.unmodifiable(_permanentFiles);
  Object? get failure => _failure;

  bool get isTerminal => _isTerminalStatus(_status);

  static bool _isTerminalStatus(GeneratedImageStorageStatus status) {
    switch (status) {
      case GeneratedImageStorageStatus.jpegSaved:
      case GeneratedImageStorageStatus.pngFallbackSaved:
      case GeneratedImageStorageStatus.skippedNotSmaller:
      case GeneratedImageStorageStatus.saved:
      case GeneratedImageStorageStatus.failed:
      case GeneratedImageStorageStatus.abandoned:
        return true;
      case GeneratedImageStorageStatus.queued:
      case GeneratedImageStorageStatus.savingSessionPng:
      case GeneratedImageStorageStatus.encoding:
      case GeneratedImageStorageStatus.publishing:
      case GeneratedImageStorageStatus.saving:
        return false;
    }
  }

  void _completeWithFile(GeneratedImageFile? file) {
    if (isTerminal) return;
    _currentFile = file;
    if (file?.mediaType == 'image/png') _originalPngFile = file;
    _permanentFiles = file == null ? const [] : [file];
    _status = GeneratedImageStorageStatus.saved;
    notifyListeners();
  }

  void _completeWithFailure(Object error) {
    if (isTerminal) return;
    _failure = error;
    _status = GeneratedImageStorageStatus.failed;
    notifyListeners();
  }

  void _setCurrentFile(
    GeneratedImageFile file, {
    required GeneratedImageStorageStatus status,
    List<GeneratedImageFile> permanentFiles = const [],
  }) {
    if (isTerminal) return;
    _currentFile = file;
    if (file.mediaType == 'image/png') _originalPngFile = file;
    _permanentFiles = List.unmodifiable(permanentFiles);
    _status = status;
    notifyListeners();
  }

  void _setStatus(GeneratedImageStorageStatus status) {
    if (isTerminal) return;
    _status = status;
    notifyListeners();
  }

  void _completeWithJpeg(
    GeneratedImageFile jpeg, {
    List<GeneratedImageFile> otherPermanentFiles = const [],
  }) {
    if (isTerminal) return;
    _currentFile = jpeg;
    _permanentFiles = List.unmodifiable([jpeg, ...otherPermanentFiles]);
    _status = GeneratedImageStorageStatus.jpegSaved;
    notifyListeners();
  }

  void _completeSkipped() {
    if (isTerminal) return;
    _status = GeneratedImageStorageStatus.skippedNotSmaller;
    notifyListeners();
  }

  void _completeWithPngFallback(GeneratedImageFile png) {
    if (isTerminal) return;
    _currentFile = png;
    _originalPngFile = png;
    _permanentFiles = List.unmodifiable([png]);
    _status = GeneratedImageStorageStatus.pngFallbackSaved;
    notifyListeners();
  }

  void _completeWithAbandoned(Object error) {
    if (isTerminal) return;
    _failure = error;
    _status = GeneratedImageStorageStatus.abandoned;
    notifyListeners();
  }
}

class GeneratedImageStorageRequest {
  final String logicalTaskId;
  final Uint8List pngBytes;
  final String fileName;
  final GeneratedImageStoragePolicy storagePolicy;
  final GeneratedImageMetadataPolicy metadataPolicy;

  const GeneratedImageStorageRequest({
    required this.logicalTaskId,
    required this.pngBytes,
    required this.fileName,
    required this.storagePolicy,
    required this.metadataPolicy,
  });
}

class GeneratedImageStoragePolicy {
  final bool jpegEnabled;
  final bool retainOriginalPng;
  final String pngOutputDirectory;
  final String jpegOutputDirectory;

  const GeneratedImageStoragePolicy({
    required this.jpegEnabled,
    required this.retainOriginalPng,
    required this.pngOutputDirectory,
    required this.jpegOutputDirectory,
  });

  const GeneratedImageStoragePolicy.pngOnly({
    required String outputDirectory,
  })  : jpegEnabled = false,
        retainOriginalPng = true,
        pngOutputDirectory = outputDirectory,
        jpegOutputDirectory = '';
}

class GeneratedImageMetadataPolicy {
  final bool eraseMetadata;
  final bool customMetadataEnabled;
  final String customMetadataContent;

  const GeneratedImageMetadataPolicy({
    required this.eraseMetadata,
    required this.customMetadataEnabled,
    required this.customMetadataContent,
  });
}

class GeneratedImageStorageCancellationToken {
  final Completer<void> _abandoned = Completer<void>();
  bool isAbandoned = false;
  GeneratedImageStorageAbandonedException? error;

  Future<void> get future => _abandoned.future;

  void abandon([
    GeneratedImageStorageAbandonedException reason =
        const GeneratedImageStorageAbandonedException(),
  ]) {
    if (isAbandoned) return;
    isAbandoned = true;
    error = reason;
    _abandoned.completeError(reason, StackTrace.current);
  }
}

class GeneratedImageStorageSubmission {
  final GeneratedImageArtifact artifact;
  final Future<GeneratedImageArtifact> completed;

  const GeneratedImageStorageSubmission._({
    required this.artifact,
    required this.completed,
  });

  /// Starts one storage operation while exposing its preview artifact now.
  ///
  /// The terminal future resolves only for a saved outcome. Publication
  /// failures update the artifact to [GeneratedImageStorageStatus.failed] and
  /// are rethrown so generation scheduling can release its success claim.
  factory GeneratedImageStorageSubmission.start({
    required Uint8List previewBytes,
    required Future<GeneratedImageFile?> Function() publish,
  }) {
    final artifact = GeneratedImageArtifact._(previewBytes: previewBytes);
    final completed = Future<GeneratedImageFile?>.sync(publish).then(
      (file) {
        artifact._completeWithFile(file);
        return artifact;
      },
      onError: (Object error, StackTrace stackTrace) {
        artifact._completeWithFailure(error);
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    return GeneratedImageStorageSubmission._(
      artifact: artifact,
      completed: completed,
    );
  }

  factory GeneratedImageStorageSubmission.run({
    required Uint8List previewBytes,
    required Future<void> Function(GeneratedImageArtifact artifact) store,
    GeneratedImageStorageStatus initialStatus =
        GeneratedImageStorageStatus.queued,
    GeneratedImageStorageCancellationToken? cancellationToken,
  }) {
    final artifact = GeneratedImageArtifact._(
      previewBytes: previewBytes,
      status: initialStatus,
    );
    final operation = Future<void>.sync(() => store(artifact));
    final terminal = cancellationToken == null
        ? operation
        : Future.any<void>([operation, cancellationToken.future]);
    final completed = terminal.then(
      (_) {
        if ((cancellationToken?.isAbandoned ?? false) && !artifact.isTerminal) {
          final error = cancellationToken!.error ??
              const GeneratedImageStorageAbandonedException();
          artifact._completeWithAbandoned(error);
          throw error;
        }
        return artifact;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (error is GeneratedImageStorageAbandonedException) {
          artifact._completeWithAbandoned(error);
        } else {
          artifact._completeWithFailure(error);
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    return GeneratedImageStorageSubmission._(
      artifact: artifact,
      completed: completed,
    );
  }

  factory GeneratedImageStorageSubmission.rejected({
    required Uint8List previewBytes,
    Object? reason,
  }) {
    final error = reason is GeneratedImageStorageAbandonedException
        ? reason
        : const GeneratedImageStorageAbandonedException();
    final artifact = GeneratedImageArtifact._(
      previewBytes: previewBytes,
      status: GeneratedImageStorageStatus.queued,
    );
    artifact._completeWithAbandoned(error);
    return GeneratedImageStorageSubmission._(
      artifact: artifact,
      completed: Future<GeneratedImageArtifact>.error(error),
    );
  }
}

abstract interface class GeneratedImageStorage {
  GeneratedImageStorageSubmission submit(GeneratedImageStorageRequest request);
}

/// Current PNG-only behavior behind the shared generated-image storage seam.
class PngGeneratedImageStorage implements GeneratedImageStorage {
  final FileService _fileService;

  PngGeneratedImageStorage({FileService? fileService})
      : _fileService = fileService ?? FileService();

  @override
  GeneratedImageStorageSubmission submit(GeneratedImageStorageRequest request) {
    return GeneratedImageStorageSubmission.start(
      previewBytes: request.pngBytes,
      publish: () async {
        final path = await _fileService.savePictureToFile(
          request.pngBytes,
          request.fileName,
          request.storagePolicy.pngOutputDirectory,
        );
        return path == null
            ? null
            : GeneratedImageFile(
                path: path,
                mediaType: 'image/png',
                isPermanent: true,
              );
      },
    );
  }
}

typedef GeneratedImageSessionDirectoryProvider = Future<Directory> Function();
typedef GeneratedImageSessionRootDirectoryProvider = Future<Directory>
    Function();

/// Shared policy router for current PNG saving and desktop JPEG storage.
///
/// JPEG jobs own an immutable request snapshot, keep a source PNG available in
/// the current session, and run through a bounded FIFO conversion queue.
class GeneratedImageStorageService implements GeneratedImageStorage {
  GeneratedImageStorageService({
    bool? desktopJpegSupported,
    GeneratedImageJpegEncoder? jpegEncoder,
    GeneratedImageSessionDirectoryProvider? sessionDirectoryProvider,
    GeneratedImageSessionRootDirectoryProvider? sessionRootDirectoryProvider,
    FileService? fileService,
    int maxConcurrentJpegJobs = 2,
    int maxPendingJpegJobs = 16,
  })  : _desktopJpegSupported =
            desktopJpegSupported ?? _supportsDesktopJpegStorage,
        _jpegEncoder = jpegEncoder ?? const IsolateGeneratedImageJpegEncoder(),
        _sessionDirectoryProvider = sessionDirectoryProvider ??
            (sessionRootDirectoryProvider == null
                ? _createDefaultSessionDirectory
                : () => _createSessionDirectoryUnderRoot(
                      sessionRootDirectoryProvider,
                    )),
        _sessionRootDirectoryProvider = sessionRootDirectoryProvider,
        _pngStorage = PngGeneratedImageStorage(fileService: fileService),
        _queue = _GeneratedImageJpegQueue(
          maxConcurrent: maxConcurrentJpegJobs,
          maxPending: maxPendingJpegJobs,
        );

  final bool _desktopJpegSupported;
  final GeneratedImageJpegEncoder _jpegEncoder;
  final GeneratedImageSessionDirectoryProvider _sessionDirectoryProvider;
  final GeneratedImageSessionRootDirectoryProvider?
      _sessionRootDirectoryProvider;
  final PngGeneratedImageStorage _pngStorage;
  final _GeneratedImageJpegQueue _queue;
  final Set<String> _reservedOutputPaths = {};
  final Set<_GeneratedImageStorageJob> _jobs = {};
  final List<Object> _cleanupFailures = [];
  Future<Directory>? _sessionDirectory;
  Future<void>? _initializeFuture;
  Future<void>? _closeFuture;
  bool _closeCompleted = false;
  bool _acceptingSubmissions = true;

  bool get isClosing => _closeFuture != null && !_closeCompleted;
  bool get isClosed => _closeCompleted;
  bool get hasPendingWork =>
      _jobs.any((job) => !job.completed) || _queue.hasPendingWork;
  bool get hasPending => hasPendingWork;
  int get pendingJobCount => _queue.pendingCount + _queue.activeCount;
  int get pendingCount => pendingJobCount;
  List<Object> get cleanupFailures => List.unmodifiable(_cleanupFailures);

  static bool get _supportsDesktopJpegStorage {
    if (kIsWeb) return false;
    return Platform.isMacOS || Platform.isWindows;
  }

  @override
  GeneratedImageStorageSubmission submit(GeneratedImageStorageRequest request) {
    if (!_acceptingSubmissions) {
      return GeneratedImageStorageSubmission.rejected(
        previewBytes: request.pngBytes,
      );
    }
    if (!_desktopJpegSupported || !request.storagePolicy.jpegEnabled) {
      return _pngStorage.submit(request);
    }
    final job = _GeneratedImageStorageJob();
    final submission = GeneratedImageStorageSubmission.run(
      previewBytes: request.pngBytes,
      cancellationToken: job.cancellationToken,
      store: (artifact) => _storeJpegMode(request, artifact, job),
    );
    job.artifact = submission.artifact;
    job.future = submission.completed;
    _jobs.add(job);
    submission.completed.then<void>(
      (_) {
        job.completed = true;
        _jobs.remove(job);
      },
      onError: (Object _, StackTrace __) {
        job.completed = true;
        _jobs.remove(job);
      },
    );
    return submission;
  }

  /// Prepare the current session and clean marked sessions from prior runs.
  /// This is idempotent and intentionally only creates a session for JPEG
  /// storage; PNG-only callers retain their legacy behavior.
  Future<void> initialize() {
    return _initializeFuture ??= _initialize();
  }

  /// Remove marked sessions from previous launches without creating a new
  /// session. Callers may use this during app startup before knowing whether
  /// JPEG mode is enabled.
  Future<void> cleanupStaleSessions() async {
    Directory? preserve;
    final current = _sessionDirectory;
    if (current != null) {
      try {
        preserve = await current;
      } catch (_) {
        preserve = null;
      }
    }
    final root = _sessionRootDirectoryProvider == null
        ? await _defaultSessionRootDirectory()
        : await _sessionRootDirectoryProvider();
    await _cleanupStaleOwnedSessions(root, preserve: preserve);
  }

  Future<void> _initialize() async {
    final directory = await (_sessionDirectory ??=
        _sessionDirectoryProvider().then((value) async {
      if (!await value.exists()) await value.create(recursive: true);
      return value;
    }));
    final root = await _sessionRootFor(directory);
    if (!_isPathWithin(root.absolute.path, directory.absolute.path) ||
        root.absolute.path == directory.absolute.path ||
        await FileSystemEntity.type(
              directory.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.directory) {
      throw ArgumentError.value(
        directory.path,
        'sessionDirectory',
        'must be a real child directory of the configured session root',
      );
    }
    if (_shouldScanSessionRoot(root, directory)) {
      await _cleanupStaleOwnedSessions(root, preserve: directory);
    }
    await _ensureOwnedSessionMarker(directory);
  }

  bool _shouldScanSessionRoot(Directory root, Directory current) {
    if (_sessionRootDirectoryProvider != null) return true;
    final rootName = root.path.split(Platform.pathSeparator).last;
    final sessionName = current.path.split(Platform.pathSeparator).last;
    return rootName == 'casrand-forge-generated-image-sessions' &&
        sessionName.startsWith('session-');
  }

  /// Stop accepting new jobs and finish or abandon already accepted work.
  /// Repeated calls return the same future, so a close prompt cannot start
  /// multiple shutdown flows.
  Future<void> close({bool abandon = false}) {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _acceptingSubmissions = false;
    final operation = abandon ? _closeAbandon() : _closeWait();
    _closeFuture = operation.then<void>(
      (_) => _closeCompleted = true,
      onError: (Object error, StackTrace stackTrace) {
        _closeCompleted = true;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    return _closeFuture!;
  }

  Future<void> waitForIdle() async {
    await _queue.waitForIdle();
    await _awaitJobs();
  }

  Future<void> abandonPending() => close(abandon: true);

  Future<void> shutdown({bool abandon = false}) => close(abandon: abandon);

  Future<void> disposeStorage({bool abandon = false}) =>
      close(abandon: abandon);

  Future<void> _closeWait() async {
    // A wait close keeps accepted work eligible to enqueue after the queue
    // stops accepting new submissions from callers.
    await _queue.close();
    await _awaitJobs();
    await _cleanupCurrentSession();
  }

  Future<void> _closeAbandon() async {
    const reason = GeneratedImageStorageAbandonedException();
    for (final job in List<_GeneratedImageStorageJob>.from(_jobs)) {
      job.abandon(reason);
    }
    await _queue.close(abandon: true);
    // Abandonment is intentionally bounded: an encoder may be in a native
    // call that cannot be interrupted. Every publish boundary checks the
    // cancellation token, and session cleanup is best effort.
    await _cleanupCurrentSession(bounded: true);
  }

  Future<void> _awaitJobs() async {
    while (_jobs.any((job) => !job.completed)) {
      final pending = _jobs
          .where((job) => !job.completed)
          .map((job) => job.future)
          .whereType<Future<GeneratedImageArtifact>>()
          .map((future) =>
              future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      await Future.wait(pending);
    }
  }

  Future<void> _storeJpegMode(
    GeneratedImageStorageRequest request,
    GeneratedImageArtifact artifact,
    _GeneratedImageStorageJob job,
  ) async {
    job.throwIfAbandoned();
    if (request.storagePolicy.jpegOutputDirectory.trim().isEmpty) {
      throw ArgumentError.value(
        request.storagePolicy.jpegOutputDirectory,
        'jpegOutputDirectory',
        'must be selected before JPEG storage is enabled',
      );
    }
    final policy = request.storagePolicy;
    final File sourcePng;
    final bool sourceIsPermanent;
    if (policy.retainOriginalPng) {
      if (policy.pngOutputDirectory.trim().isEmpty) {
        throw ArgumentError.value(
          policy.pngOutputDirectory,
          'pngOutputDirectory',
          'must be selected when retaining original PNG files',
        );
      }
      sourcePng = File(
        '${policy.pngOutputDirectory}${Platform.pathSeparator}'
        '${request.fileName}',
      );
      sourceIsPermanent = true;
    } else {
      artifact._setStatus(GeneratedImageStorageStatus.savingSessionPng);
      await initialize();
      job.throwIfAbandoned();
      final session = await _sessionDirectory;
      if (session == null) {
        throw StateError('Generated-image session was not initialized.');
      }
      sourcePng = File(
        '${session.path}${Platform.pathSeparator}${request.fileName}',
      );
      sourceIsPermanent = false;
    }
    await _writeNewFileAtomically(
      sourcePng,
      request.pngBytes,
      cancellationToken: job.cancellationToken,
    );
    job.throwIfAbandoned();
    final sourceArtifact = GeneratedImageFile(
      path: sourcePng.absolute.path,
      mediaType: 'image/png',
      isPermanent: sourceIsPermanent,
    );
    artifact._setCurrentFile(
      sourceArtifact,
      status: GeneratedImageStorageStatus.queued,
      permanentFiles: sourceIsPermanent ? [sourceArtifact] : const [],
    );

    await _queue.schedule(() async {
      job.throwIfAbandoned();
      artifact._setStatus(GeneratedImageStorageStatus.encoding);
      final result = await _jpegEncoder.encode(request.pngBytes);
      job.throwIfAbandoned();
      if (result.status ==
          GeneratedImageJpegEncodingStatus.transparencyUnsupported) {
        if (sourceIsPermanent) {
          artifact._completeWithPngFallback(sourceArtifact);
          return;
        }
        final fallbackPng = File(
          '${policy.jpegOutputDirectory}${Platform.pathSeparator}'
          '${request.fileName}',
        );
        await _writeNewFileAtomically(
          fallbackPng,
          request.pngBytes,
          cancellationToken: job.cancellationToken,
        );
        job.throwIfAbandoned();
        artifact._completeWithPngFallback(GeneratedImageFile(
          path: fallbackPng.absolute.path,
          mediaType: 'image/png',
          isPermanent: true,
        ));
        return;
      }
      if (!result.isSuccess) {
        throw StateError(
          result.errorMessage ??
              'JPEG conversion ended with ${result.status.name}.',
        );
      }
      final jpegBytes = result.jpegBytes!;
      job.throwIfAbandoned();
      if (jpegBytes.length >= request.pngBytes.length) {
        artifact._completeSkipped();
        return;
      }

      artifact._setStatus(GeneratedImageStorageStatus.publishing);
      final jpegName = _replaceExtension(request.fileName, '.jpg');
      final jpegFile = File(
        '${request.storagePolicy.jpegOutputDirectory}'
        '${Platform.pathSeparator}$jpegName',
      );
      await _writeNewFileAtomically(
        jpegFile,
        jpegBytes,
        cancellationToken: job.cancellationToken,
      );
      job.throwIfAbandoned();
      final reopened = await jpegFile.readAsBytes();
      job.throwIfAbandoned();
      if (!listEquals(reopened, jpegBytes)) {
        await jpegFile.delete();
        throw const FileSystemException(
          'Published JPEG did not match the verified candidate.',
        );
      }
      artifact._completeWithJpeg(
          GeneratedImageFile(
            path: jpegFile.absolute.path,
            mediaType: 'image/jpeg',
            isPermanent: true,
          ),
          otherPermanentFiles: sourceIsPermanent ? [sourceArtifact] : const []);
    }, cancellationToken: job.cancellationToken);
  }

  Future<Directory> _sessionRootFor(Directory session) async {
    final provider = _sessionRootDirectoryProvider;
    if (provider != null) return provider();
    return session.parent;
  }

  static const _sessionMarkerName = '.casrand-session';
  static const _sessionMarkerPrefix = 'CasRand Forge generated-image session';

  Future<void> _ensureOwnedSessionMarker(Directory session) async {
    if (!await session.exists()) await session.create(recursive: true);
    final marker = File(
      '${session.path}${Platform.pathSeparator}$_sessionMarkerName',
    );
    if (await marker.exists()) {
      // A marker from a previous launch is still a valid ownership proof for
      // the current explicitly supplied session directory.
      return;
    }
    final markerDirectory = Directory(marker.path);
    if (await markerDirectory.exists()) {
      final owner = File(
        '${markerDirectory.path}${Platform.pathSeparator}owner',
      );
      if (!await owner.exists()) {
        await owner.writeAsString(
          '$_sessionMarkerPrefix\n'
          'launch=$pid-${DateTime.now().microsecondsSinceEpoch}\n',
          flush: true,
        );
      }
      return;
    }
    await marker.writeAsString(
      '$_sessionMarkerPrefix\nlaunch=$pid-${DateTime.now().microsecondsSinceEpoch}\n',
      flush: true,
    );
  }

  Future<bool> _hasOwnedSessionMarker(Directory session) async {
    final markerPath =
        '${session.path}${Platform.pathSeparator}$_sessionMarkerName';
    final marker = File(markerPath);
    if (await marker.exists()) {
      try {
        final content = await marker.readAsString();
        return content.startsWith(_sessionMarkerPrefix);
      } catch (_) {
        return false;
      }
    }
    // Accept a marker directory as well. This keeps cleanup compatible with
    // older fixtures that used a directory marker to avoid exposing metadata
    // as a generated-image file.
    final markerDirectory = Directory(markerPath);
    if (await markerDirectory.exists()) {
      final owner = File(
        '${markerDirectory.path}${Platform.pathSeparator}owner',
      );
      try {
        if (await owner.exists()) {
          final content = await owner.readAsString();
          return content.startsWith(_sessionMarkerPrefix);
        }
      } catch (_) {
        // Cleanup must never prevent startup.
      }
    }
    return false;
  }

  Future<void> _cleanupStaleOwnedSessions(
    Directory root, {
    Directory? preserve,
  }) async {
    try {
      if (!await root.exists()) return;
      final rootAbsolute = root.absolute;
      final preservePath = preserve?.absolute.path;
      await for (final entity in root.list(
        followLinks: false,
        recursive: false,
      )) {
        if (entity is! Directory) continue;
        if (await FileSystemEntity.type(
              entity.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.directory) {
          continue;
        }
        final candidate = entity.absolute;
        if (!_isPathWithin(rootAbsolute.path, candidate.path) ||
            candidate.path == preservePath ||
            !await _hasOwnedSessionMarker(candidate)) {
          continue;
        }
        try {
          await candidate.delete(recursive: true);
        } catch (error) {
          _cleanupFailures.add(error);
        }
      }
    } catch (error) {
      _cleanupFailures.add(error);
    }
  }

  Future<void> _cleanupCurrentSession({bool bounded = false}) async {
    final future = _sessionDirectory;
    if (future == null) return;
    Directory? session;
    try {
      session = bounded
          ? await future.timeout(const Duration(milliseconds: 250))
          : await future;
    } catch (error) {
      _cleanupFailures.add(error);
      if (bounded) {
        // A slow provider must not hold an abandon close open. If it later
        // resolves, perform the same owned-marker check asynchronously.
        future.then<void>(_deleteOwnedSession,
            onError: (Object _, StackTrace __) {});
      }
      return;
    }
    await _deleteOwnedSession(session);
  }

  Future<void> _deleteOwnedSession(Directory session) async {
    if (!await session.exists()) return;
    if (!await _hasOwnedSessionMarker(session)) return;
    try {
      await session.delete(recursive: true);
    } catch (error) {
      _cleanupFailures.add(error);
    }
  }

  static bool _isPathWithin(String rootPath, String candidatePath) {
    final root = _normalizePath(rootPath);
    final candidate = _normalizePath(candidatePath);
    return candidate == root ||
        candidate.startsWith('$root${Platform.pathSeparator}');
  }

  static String _normalizePath(String path) {
    var normalized = path;
    while (normalized.length > 1 &&
        (normalized.endsWith('/') || normalized.endsWith('\\'))) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static String _replaceExtension(String fileName, String extension) {
    final dot = fileName.lastIndexOf('.');
    final stem = dot <= 0 ? fileName : fileName.substring(0, dot);
    return '$stem$extension';
  }

  Future<void> _writeNewFileAtomically(
    File finalFile,
    Uint8List bytes, {
    GeneratedImageStorageCancellationToken? cancellationToken,
  }) async {
    final reservation = finalFile.absolute.path;
    if (!_reservedOutputPaths.add(reservation)) {
      throw FileSystemException(
        'Another generated image already reserved this output path.',
        reservation,
      );
    }
    try {
      await _writeReservedFileAtomically(
        finalFile,
        bytes,
        cancellationToken: cancellationToken,
      );
    } finally {
      _reservedOutputPaths.remove(reservation);
    }
  }

  static Future<void> _writeReservedFileAtomically(
    File finalFile,
    Uint8List bytes, {
    GeneratedImageStorageCancellationToken? cancellationToken,
  }) async {
    final parent = finalFile.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    if (await finalFile.exists()) {
      throw FileSystemException(
        'Refusing to overwrite an existing generated image.',
        finalFile.path,
      );
    }
    final tempFile = File(
      '${parent.path}${Platform.pathSeparator}.${finalFile.uri.pathSegments.last}'
      '.${DateTime.now().microsecondsSinceEpoch}.$pid.tmp',
    );
    RandomAccessFile? handle;
    try {
      handle = await tempFile.open(mode: FileMode.writeOnly);
      await handle.writeFrom(bytes);
      await handle.flush();
      await handle.close();
      handle = null;
      if (cancellationToken?.isAbandoned ?? false) {
        throw cancellationToken!.error ??
            const GeneratedImageStorageAbandonedException();
      }
      if (await finalFile.exists()) {
        throw FileSystemException(
          'Refusing to overwrite an existing generated image.',
          finalFile.path,
        );
      }
      await tempFile.rename(finalFile.path);
    } catch (_) {
      await handle?.close();
      if (await tempFile.exists()) await tempFile.delete();
      rethrow;
    }
  }

  static Future<Directory> _createDefaultSessionDirectory() async {
    final root = await _defaultSessionRootDirectory();
    await root.create(recursive: true);
    final session = Directory(
      '${root.path}${Platform.pathSeparator}'
      'session-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    await session.create();
    await File('${session.path}${Platform.pathSeparator}.casrand-session')
        .writeAsString(
      'CasRand Forge generated-image session\n'
      'launch=$pid-${DateTime.now().microsecondsSinceEpoch}\n',
      flush: true,
    );
    return session;
  }

  static Future<Directory> _defaultSessionRootDirectory() async {
    final temporary = await getTemporaryDirectory();
    return Directory(
      '${temporary.path}${Platform.pathSeparator}'
      'casrand-forge-generated-image-sessions',
    );
  }

  static Future<Directory> _createSessionDirectoryUnderRoot(
    GeneratedImageSessionRootDirectoryProvider? rootProvider,
  ) async {
    if (rootProvider == null) return _createDefaultSessionDirectory();
    final root = await rootProvider();
    await root.create(recursive: true);
    final session = Directory(
      '${root.path}${Platform.pathSeparator}'
      'session-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    await session.create();
    await File('${session.path}${Platform.pathSeparator}.casrand-session')
        .writeAsString(
      'CasRand Forge generated-image session\n'
      'launch=$pid-${DateTime.now().microsecondsSinceEpoch}\n',
      flush: true,
    );
    return session;
  }
}

class _GeneratedImageStorageJob {
  final GeneratedImageStorageCancellationToken cancellationToken =
      GeneratedImageStorageCancellationToken();
  GeneratedImageArtifact? artifact;
  Future<GeneratedImageArtifact>? future;
  bool completed = false;

  void throwIfAbandoned() {
    if (!cancellationToken.isAbandoned) return;
    throw cancellationToken.error ??
        const GeneratedImageStorageAbandonedException();
  }

  void abandon(GeneratedImageStorageAbandonedException reason) {
    cancellationToken.abandon(reason);
    final current = artifact;
    if (current != null && !current.isTerminal) {
      current._completeWithAbandoned(reason);
    }
  }
}

class _GeneratedImageJpegQueue {
  _GeneratedImageJpegQueue({
    required this.maxConcurrent,
    required this.maxPending,
  }) {
    if (maxConcurrent < 1) {
      throw ArgumentError.value(maxConcurrent, 'maxConcurrent');
    }
    if (maxPending < 0) throw ArgumentError.value(maxPending, 'maxPending');
  }

  final int maxConcurrent;
  final int maxPending;
  final ListQueue<_QueuedGeneratedImageJpegJob> _pending = ListQueue();
  final Set<_QueuedGeneratedImageJpegJob> _activeJobs = {};
  int _active = 0;
  bool _closed = false;
  bool _abandoning = false;
  Completer<void>? _idleCompleter;

  bool get hasPendingWork => _active > 0 || _pending.isNotEmpty;
  int get pendingCount => _pending.length;
  int get activeCount => _active;

  Future<void> schedule(
    Future<void> Function() operation, {
    GeneratedImageStorageCancellationToken? cancellationToken,
  }) {
    if (_abandoning) {
      return Future<void>.error(
        cancellationToken?.error ??
            const GeneratedImageStorageAbandonedException(),
      );
    }
    if (_closed && cancellationToken == null) {
      return Future<void>.error(StateError(
        'The generated-image JPEG queue is closed.',
      ));
    }
    if (_active >= maxConcurrent && _pending.length >= maxPending) {
      return Future<void>.error(StateError(
        'The generated-image JPEG queue is full.',
      ));
    }
    final completer = Completer<void>();
    final job = _QueuedGeneratedImageJpegJob(
      operation,
      completer,
      cancellationToken,
    );
    if (cancellationToken?.isAbandoned ?? false) {
      completer.completeError(
        cancellationToken!.error ??
            const GeneratedImageStorageAbandonedException(),
      );
      return completer.future;
    }
    _pending.add(job);
    _drain();
    return completer.future;
  }

  Future<void> close({bool abandon = false}) {
    _closed = true;
    if (abandon) {
      _abandoning = true;
      for (final job in List<_QueuedGeneratedImageJpegJob>.from(_pending)) {
        _pending.remove(job);
        _abandonJob(job);
      }
      for (final job in List<_QueuedGeneratedImageJpegJob>.from(_activeJobs)) {
        _abandonJob(job);
      }
      _completeIdleIfReady();
      return Future<void>.value();
    }
    return waitForIdle();
  }

  Future<void> waitForIdle() {
    if (!hasPendingWork) return Future<void>.value();
    return (_idleCompleter ??= Completer<void>()).future;
  }

  void _abandonJob(_QueuedGeneratedImageJpegJob job) {
    job.cancellationToken?.abandon();
    if (!job.completer.isCompleted) {
      job.completer.completeError(
        job.cancellationToken?.error ??
            const GeneratedImageStorageAbandonedException(),
      );
    }
  }

  void _drain() {
    while (_active < maxConcurrent && _pending.isNotEmpty) {
      final job = _pending.removeFirst();
      _active++;
      _activeJobs.add(job);
      Future<void>.sync(job.operation).then<void>(
        (_) {
          if (!job.completer.isCompleted) job.completer.complete();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!job.completer.isCompleted) {
            job.completer.completeError(error, stackTrace);
          }
        },
      ).whenComplete(() {
        _active--;
        _activeJobs.remove(job);
        _completeIdleIfReady();
        _drain();
      }).catchError((_) {});
    }
    _completeIdleIfReady();
  }

  void _completeIdleIfReady() {
    if (hasPendingWork) return;
    final completer = _idleCompleter;
    _idleCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
}

class _QueuedGeneratedImageJpegJob {
  const _QueuedGeneratedImageJpegJob(
    this.operation,
    this.completer,
    this.cancellationToken,
  );

  final Future<void> Function() operation;
  final Completer<void> completer;
  final GeneratedImageStorageCancellationToken? cancellationToken;
}
