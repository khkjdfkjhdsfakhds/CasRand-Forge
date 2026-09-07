import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/services/generated_image_jpeg_encoder.dart';
import 'package:nai_casrand/data/services/image_service.dart';
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
  GeneratedImageSaveDestination? _saveDestination;
  ImageMetadataEmbeddingMode? _metadataEmbeddingMode;
  Object? _metadataFailure;

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
  GeneratedImageSaveDestination? get saveDestination => _saveDestination;
  ImageMetadataEmbeddingMode? get metadataEmbeddingMode =>
      _metadataEmbeddingMode;
  Object? get metadataFailure => _metadataFailure;

  bool get isDurablySaved =>
      _permanentFiles.isNotEmpty ||
      _saveDestination == GeneratedImageSaveDestination.androidGallery;

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
    _saveDestination =
        file == null ? null : GeneratedImageSaveDestination.fileSystem;
    _status = GeneratedImageStorageStatus.saved;
    notifyListeners();
  }

  void _completeWithPathlessPublication(
    GeneratedImageSaveDestination destination,
  ) {
    if (isTerminal) return;
    _saveDestination = destination;
    _status = GeneratedImageStorageStatus.saved;
    notifyListeners();
  }

  void _completeWithFailure(Object error) {
    if (isTerminal) return;
    _failure = error;
    _status = GeneratedImageStorageStatus.failed;
    notifyListeners();
  }

  void _setMetadataEmbeddingMode(ImageMetadataEmbeddingMode mode) {
    if (isTerminal) return;
    _metadataEmbeddingMode = mode;
    notifyListeners();
  }

  void _setMetadataFailure(Object error) {
    if (isTerminal) return;
    _metadataFailure = error;
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

  GeneratedImageStorageRequest({
    required this.logicalTaskId,
    required Uint8List pngBytes,
    required this.fileName,
    required this.storagePolicy,
    required this.metadataPolicy,
  }) : pngBytes = Uint8List.fromList(pngBytes).asUnmodifiableView();
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
  /// are rethrown so callers can offer a storage-only retry for the same paid
  /// response bytes.
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

typedef GeneratedImageMetadataProcessor = Future<ImageMetadataEmbeddingResult>
    Function(
  Uint8List imageBytes,
  String metadata,
);

Future<ImageMetadataEmbeddingResult> _embedGeneratedImageMetadata(
  (Uint8List, String) input,
) {
  return ImageService().embedMetadataWithOutcome(input.$1, input.$2);
}

Future<ImageMetadataEmbeddingResult> _defaultGeneratedImageMetadataProcessor(
  Uint8List imageBytes,
  String metadata,
) {
  return compute(_embedGeneratedImageMetadata, (imageBytes, metadata));
}

Future<Uint8List> _prepareGeneratedImageBytes(
  GeneratedImageStorageRequest request,
  GeneratedImageMetadataProcessor metadataProcessor,
  GeneratedImageArtifact artifact,
) async {
  if (!request.metadataPolicy.eraseMetadata) {
    return request.pngBytes;
  }
  final metadata = request.metadataPolicy.customMetadataEnabled
      ? request.metadataPolicy.customMetadataContent
      : '';
  try {
    final result = await metadataProcessor(request.pngBytes, metadata);
    artifact._setMetadataEmbeddingMode(result.mode);
    return result.bytes;
  } catch (error) {
    // Preserving the paid image is the primary invariant. A metadata failure
    // is retained as a visible warning while the unmodified response is still
    // published durably.
    artifact._setMetadataFailure(error);
    return request.pngBytes;
  }
}

/// Current PNG-only behavior behind the shared generated-image storage seam.
class PngGeneratedImageStorage implements GeneratedImageStorage {
  final FileService _fileService;
  final GeneratedImageMetadataProcessor _metadataProcessor;
  final Expando<({GeneratedImageSaveResult result, Future<String> digest})>
      _publications = Expando();

  PngGeneratedImageStorage({
    FileService? fileService,
    GeneratedImageMetadataProcessor? metadataProcessor,
  })  : _fileService = fileService ?? FileService(),
        _metadataProcessor =
            metadataProcessor ?? _defaultGeneratedImageMetadataProcessor;

  @override
  GeneratedImageStorageSubmission submit(
    GeneratedImageStorageRequest request, {
    GeneratedImageStorageCancellationToken? cancellationToken,
  }) {
    return GeneratedImageStorageSubmission.run(
      previewBytes: request.pngBytes,
      cancellationToken: cancellationToken,
      initialStatus: GeneratedImageStorageStatus.saving,
      store: (artifact) async {
        final storageBytes = await _prepareGeneratedImageBytes(
          request,
          _metadataProcessor,
          artifact,
        );
        if (cancellationToken?.isAbandoned ?? false) {
          throw cancellationToken!.error ??
              const GeneratedImageStorageAbandonedException();
        }
        final previous = _publications[request];
        GeneratedImageSaveResult? result;
        if (previous != null) {
          final path = previous.result.path;
          if (path == null) {
            result = previous.result;
          } else {
            final type = await FileSystemEntity.type(path, followLinks: false);
            if (type != FileSystemEntityType.notFound) {
              final digest = await compute(_generatedImageDigest, storageBytes);
              if (type != FileSystemEntityType.file ||
                  await previous.digest != digest ||
                  await compute(_generatedImageDigest,
                          await File(path).readAsBytes()) !=
                      digest) {
                throw FileSystemException(
                    'A previously saved image was changed; preserving the existing file.',
                    path);
              }
              result = previous.result;
            }
          }
        }
        if (cancellationToken?.isAbandoned ?? false) {
          throw cancellationToken!.error ??
              const GeneratedImageStorageAbandonedException();
        }
        result ??= await _fileService.saveGeneratedImage(
          storageBytes,
          request.fileName,
          request.storagePolicy.pngOutputDirectory,
        );
        final path = result.path;
        if (previous == null || !identical(previous.result, result)) {
          // Receipt hashing is background bookkeeping, not part of the first
          // publication's completion boundary. A retry awaits this exact digest.
          final digest = path == null
              ? Future<String>.value('')
              : compute(_generatedImageDigest, storageBytes);
          unawaited(digest.then<void>((_) {}, onError: (Object _) {}));
          _publications[request] = (result: result, digest: digest);
        }
        if (path == null) {
          artifact._completeWithPathlessPublication(result.destination);
          return;
        }
        artifact._completeWithFile(GeneratedImageFile(
          path: path,
          mediaType: 'image/png',
          isPermanent: true,
        ));
      },
    );
  }
}

String _generatedImageDigest(Uint8List bytes) =>
    sha256.convert(bytes).toString();

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
    GeneratedImageMetadataProcessor? metadataProcessor,
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
        _metadataProcessor =
            metadataProcessor ?? _defaultGeneratedImageMetadataProcessor,
        _pngStorage = PngGeneratedImageStorage(
          fileService: fileService,
          metadataProcessor: metadataProcessor,
        ),
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
  final GeneratedImageMetadataProcessor _metadataProcessor;
  final _GeneratedImageJpegQueue _queue;
  final Set<String> _reservedOutputPaths = {};
  // Receipts belong to the immutable paid response request. Expando avoids
  // keeping completed requests/images alive solely for storage retry support.
  final Expando<Map<String, String>> _publishedDigests = Expando();
  final Set<_GeneratedImageStorageJob> _jobs = {};
  final List<Object> _cleanupFailures = [];
  Future<Directory>? _sessionDirectory;
  Future<void>? _initializeFuture;
  Future<void>? _closeFuture;
  Future<void> _jpegEnqueueTail = Future<void>.value();
  bool _closeCompleted = false;
  bool _acceptingSubmissions = true;

  bool get isClosing => _closeFuture != null && !_closeCompleted;
  bool get isClosed => _closeCompleted;
  bool get hasPendingWork =>
      _jobs.any((job) => !job.completed) || _queue.hasPendingWork;
  bool get hasPending => hasPendingWork;
  int get pendingJobCount => _jobs.where((job) => !job.completed).length;
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
    final job = _GeneratedImageStorageJob();
    if (!_desktopJpegSupported || !request.storagePolicy.jpegEnabled) {
      return _trackSubmission(
        job,
        _pngStorage.submit(request, cancellationToken: job.cancellationToken),
      );
    }
    final enqueueTurn = _reserveJpegEnqueueTurn();
    final submission = GeneratedImageStorageSubmission.run(
      previewBytes: request.pngBytes,
      cancellationToken: job.cancellationToken,
      store: (artifact) => _storeJpegMode(request, artifact, job, enqueueTurn),
    );
    return _trackSubmission(job, submission);
  }

  GeneratedImageStorageSubmission _trackSubmission(
    _GeneratedImageStorageJob job,
    GeneratedImageStorageSubmission submission,
  ) {
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

  _GeneratedImageJpegEnqueueTurn _reserveJpegEnqueueTurn() {
    final turn = _GeneratedImageJpegEnqueueTurn(_jpegEnqueueTail);
    _jpegEnqueueTail = turn.released;
    return turn;
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
    _GeneratedImageJpegEnqueueTurn enqueueTurn,
  ) async {
    var enqueueTurnReleased = false;
    final ownedDigests = _publishedDigests[request] ??= <String, String>{};
    try {
      job.throwIfAbandoned();
      final storagePngBytes = await _prepareGeneratedImageBytes(
        request,
        _metadataProcessor,
        artifact,
      );
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
        storagePngBytes,
        cancellationToken: job.cancellationToken,
        ownedDigests: ownedDigests,
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

      // submit() order is the public FIFO contract. Source PNG preparation
      // happens asynchronously, so reserve the enqueue turn up front rather
      // than letting whichever write finishes first reorder conversions.
      await enqueueTurn.previous;
      job.throwIfAbandoned();
      late final Future<void> scheduled;
      try {
        scheduled = _queue.schedule(() async {
          job.throwIfAbandoned();
          artifact._setStatus(GeneratedImageStorageStatus.encoding);
          final result = await _jpegEncoder.encode(storagePngBytes);
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
              storagePngBytes,
              cancellationToken: job.cancellationToken,
              ownedDigests: ownedDigests,
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
          if (jpegBytes.length >= storagePngBytes.length) {
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
              storagePngBytes,
              cancellationToken: job.cancellationToken,
              ownedDigests: ownedDigests,
            );
            job.throwIfAbandoned();
            artifact._completeWithPngFallback(GeneratedImageFile(
              path: fallbackPng.absolute.path,
              mediaType: 'image/png',
              isPermanent: true,
            ));
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
            ownedDigests: ownedDigests,
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
              otherPermanentFiles:
                  sourceIsPermanent ? [sourceArtifact] : const []);
        }, cancellationToken: job.cancellationToken);
      } finally {
        enqueueTurn.release();
        enqueueTurnReleased = true;
      }
      await scheduled;
    } finally {
      if (!enqueueTurnReleased) enqueueTurn.release();
    }
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
    Map<String, String>? ownedDigests,
  }) async {
    final reservation = finalFile.absolute.path;
    if (!_reservedOutputPaths.add(reservation)) {
      throw FileSystemException(
        'Another generated image already reserved this output path.',
        reservation,
      );
    }
    try {
      final digest = ownedDigests == null
          ? null
          : await compute(_generatedImageDigest, bytes);
      final existingType = await FileSystemEntity.type(
        finalFile.path,
        followLinks: false,
      );
      if (existingType != FileSystemEntityType.notFound &&
          ownedDigests?[reservation] != null) {
        // Never infer ownership just from a matching name/task ID. Only a
        // successful write by this request plus unchanged bytes is resumable.
        if (existingType != FileSystemEntityType.file ||
            ownedDigests![reservation] != digest ||
            await compute(
                    _generatedImageDigest, await finalFile.readAsBytes()) !=
                digest) {
          throw FileSystemException(
            'A previously saved image was changed; preserving the existing file.',
            finalFile.path,
          );
        }
        return;
      }
      await _writeReservedFileAtomically(
        finalFile,
        bytes,
        cancellationToken: cancellationToken,
      );
      if (digest != null) ownedDigests![reservation] = digest;
    } finally {
      _reservedOutputPaths.remove(reservation);
    }
  }

  static Future<void> _writeReservedFileAtomically(
    File finalFile,
    Uint8List bytes, {
    GeneratedImageStorageCancellationToken? cancellationToken,
  }) async {
    return FileService.writeNewImageFileAtomically(
      finalFile,
      bytes,
      beforePublish: () {
        if (cancellationToken?.isAbandoned ?? false) {
          throw cancellationToken!.error ??
              const GeneratedImageStorageAbandonedException();
        }
      },
    );
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

class _GeneratedImageJpegEnqueueTurn {
  _GeneratedImageJpegEnqueueTurn(this.previous);

  final Future<void> previous;
  final Completer<void> _released = Completer<void>();

  Future<void> get released => _released.future;

  void release() {
    if (!_released.isCompleted) _released.complete();
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
