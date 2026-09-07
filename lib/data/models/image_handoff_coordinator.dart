import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:image_size_getter/image_size_getter.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/payload_config.dart';

class ImageDimensions {
  final int width;
  final int height;

  const ImageDimensions({required this.width, required this.height});
}

typedef ImageDimensionsReader = Future<ImageDimensions> Function(
  Uint8List bytes,
);

typedef ImagePreviewCreator = Future<Uint8List> Function(
  Uint8List bytes,
  ImageDimensions dimensions,
);

typedef _TargetImageState = ({Object config, int revision});

enum ImageHandoffAction { imageToImage, inpaint, enhance, directorTools }

enum ImageHandoffPhase { idle, preparing, failure }

ImageDimensions _readImageDimensionsInBackground(Uint8List bytes) {
  final size = ImageSizeGetter.getSize(MemoryInput(bytes));
  if (size.width <= 0 || size.height <= 0) {
    throw const FormatException('Image dimensions are unavailable.');
  }
  return ImageDimensions(width: size.width, height: size.height);
}

Future<ImageDimensions> _defaultImageDimensionsReader(Uint8List bytes) {
  return compute(_readImageDimensionsInBackground, bytes);
}

const int _handoffPreviewLongestEdge = 512;

Uint8List _resizeHandoffPreview(Uint8List bytes) {
  final source = img.decodeImage(bytes);
  if (source == null) {
    throw const FormatException('Image preview could not be decoded.');
  }
  final landscape = source.width >= source.height;
  final preview = img.copyResize(
    source,
    width: landscape ? _handoffPreviewLongestEdge : null,
    height: landscape ? null : _handoffPreviewLongestEdge,
    interpolation: img.Interpolation.linear,
  );
  return Uint8List.fromList(img.encodePng(preview, level: 3));
}

Future<Uint8List> _defaultImagePreviewCreator(
  Uint8List bytes,
  ImageDimensions dimensions,
) {
  if (dimensions.width <= _handoffPreviewLongestEdge &&
      dimensions.height <= _handoffPreviewLongestEdge) {
    return SynchronousFuture(bytes);
  }
  return compute(_resizeHandoffPreview, bytes);
}

/// Coordinates result-image handoffs so navigation can paint before image
/// preparation begins. Only the latest request is allowed to commit.
class ImageHandoffCoordinator extends ChangeNotifier {
  final PayloadConfig payloadConfig;
  final NavigationRequest navigation;
  final ImageDimensionsReader _readDimensions;
  final ImagePreviewCreator _createPreview;

  ImageHandoffPhase _phase = ImageHandoffPhase.idle;
  ImageHandoffAction? _action;
  Uint8List? _bytes;
  Map<String, dynamic>? _metadata;
  String? _prompt;
  String? _model;
  Object? _error;
  int _generation = 0;

  ImageHandoffCoordinator({
    required this.payloadConfig,
    required this.navigation,
    ImageDimensionsReader? readDimensions,
    ImagePreviewCreator? createPreview,
  })  : _readDimensions = readDimensions ?? _defaultImageDimensionsReader,
        _createPreview = createPreview ?? _defaultImagePreviewCreator;

  ImageHandoffPhase get phase => _phase;
  ImageHandoffAction? get action => _action;
  Object? get error => _error;

  bool isPreparing(ImageHandoffAction action) =>
      _phase == ImageHandoffPhase.preparing && _action == action;

  bool hasFailed(ImageHandoffAction action) =>
      _phase == ImageHandoffPhase.failure && _action == action;

  bool useAsBaseImage(Uint8List bytes) {
    return _start(
      action: ImageHandoffAction.imageToImage,
      bytes: bytes,
      navigate: () => navigation.goToI2i(I2iEntryMode.baseImage),
    );
  }

  bool sendToEnhance(
    Uint8List bytes, {
    required Map<String, dynamic> metadata,
    String? prompt,
    String? model,
  }) {
    return _start(
      action: ImageHandoffAction.enhance,
      bytes: bytes,
      metadata: metadata,
      prompt: prompt,
      model: model,
      navigate: () => navigation.goTo(AppDestination.enhance),
    );
  }

  bool sendToDirectorTools(Uint8List bytes) {
    return _start(
      action: ImageHandoffAction.directorTools,
      bytes: bytes,
      navigate: () => navigation.goTo(AppDestination.directorTools),
    );
  }

  bool sendToInpaint(Uint8List bytes) {
    return _start(
      action: ImageHandoffAction.inpaint,
      bytes: bytes,
      navigate: () => navigation.goToI2i(I2iEntryMode.baseImage),
    );
  }

  bool retry() {
    final action = _action;
    final bytes = _bytes;
    if (_phase != ImageHandoffPhase.failure ||
        action == null ||
        bytes == null) {
      return false;
    }
    switch (action) {
      case ImageHandoffAction.imageToImage:
        return _start(
          action: action,
          bytes: bytes,
          navigate: () => navigation.goToI2i(I2iEntryMode.baseImage),
        );
      case ImageHandoffAction.enhance:
        return _start(
          action: action,
          bytes: bytes,
          metadata: _metadata,
          prompt: _prompt,
          model: _model,
          navigate: () => navigation.goTo(AppDestination.enhance),
        );
      case ImageHandoffAction.inpaint:
        return _start(
          action: action,
          bytes: bytes,
          navigate: () => navigation.goToI2i(I2iEntryMode.baseImage),
        );
      case ImageHandoffAction.directorTools:
        return _start(
          action: action,
          bytes: bytes,
          navigate: () => navigation.goTo(AppDestination.directorTools),
        );
    }
  }

  bool _start({
    required ImageHandoffAction action,
    required Uint8List bytes,
    required VoidCallback navigate,
    Map<String, dynamic>? metadata,
    String? prompt,
    String? model,
  }) {
    if (_phase == ImageHandoffPhase.preparing &&
        _action == action &&
        identical(_bytes, bytes)) {
      return false;
    }

    final requestGeneration = ++_generation;
    _phase = ImageHandoffPhase.preparing;
    _action = action;
    _bytes = bytes;
    _metadata = metadata;
    _prompt = prompt;
    _model = model;
    _error = null;
    final targetImageState = _targetImageState(action);
    navigate();
    notifyListeners();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prepareAndCommit(
        requestGeneration: requestGeneration,
        targetImageState: targetImageState,
        action: action,
        bytes: bytes,
      );
    });
    return true;
  }

  Future<void> _prepareAndCommit({
    required int requestGeneration,
    required _TargetImageState targetImageState,
    required ImageHandoffAction action,
    required Uint8List bytes,
  }) async {
    try {
      final dimensions = await _readDimensions(bytes);
      if (requestGeneration != _generation) return;
      if (!_targetImageStateMatches(action, targetImageState)) {
        _finishSuperseded(requestGeneration);
        return;
      }

      Uint8List? previewBytes;
      if (action == ImageHandoffAction.imageToImage ||
          action == ImageHandoffAction.inpaint) {
        previewBytes = await _createPreview(bytes, dimensions);
        if (requestGeneration != _generation) return;
        if (!_targetImageStateMatches(action, targetImageState)) {
          _finishSuperseded(requestGeneration);
          return;
        }
      }

      switch (action) {
        case ImageHandoffAction.imageToImage:
          final replacing = payloadConfig.i2iConfig.hasImage;
          payloadConfig.i2iConfig.setPreparedImage(
            bytes,
            width: dimensions.width,
            height: dimensions.height,
            previewBytes: previewBytes,
          );
          payloadConfig.noteI2iImported(
            replacing: replacing,
            explicitUse: true,
          );
        case ImageHandoffAction.enhance:
          payloadConfig.importMetadataToFixedProfile(
            _metadata ?? const {},
            prompt: _prompt,
            model: _model,
          );
          payloadConfig.enhanceConfig.setPreparedImage(
            bytes,
            width: dimensions.width,
            height: dimensions.height,
          );
        case ImageHandoffAction.inpaint:
          final replacing = payloadConfig.i2iConfig.hasImage;
          payloadConfig.i2iConfig.setPreparedImage(
            bytes,
            width: dimensions.width,
            height: dimensions.height,
            previewBytes: previewBytes,
          );
          payloadConfig.noteI2iImported(
            replacing: replacing,
            explicitUse: true,
          );
          navigation.goToI2i(I2iEntryMode.inpaint);
        case ImageHandoffAction.directorTools:
          payloadConfig.directorToolConfig.setPreparedImage(
            bytes,
            width: dimensions.width,
            height: dimensions.height,
          );
      }
      _phase = ImageHandoffPhase.idle;
      _error = null;
      notifyListeners();
    } catch (error) {
      if (requestGeneration != _generation) return;
      if (!_targetImageStateMatches(action, targetImageState)) {
        _finishSuperseded(requestGeneration);
        return;
      }
      _phase = ImageHandoffPhase.failure;
      _error = error;
      notifyListeners();
    }
  }

  _TargetImageState _targetImageState(ImageHandoffAction action) =>
      switch (action) {
        ImageHandoffAction.imageToImage || ImageHandoffAction.inpaint => (
            config: payloadConfig.i2iConfig,
            revision: payloadConfig.i2iConfig.imageRevision,
          ),
        ImageHandoffAction.enhance => (
            config: payloadConfig.enhanceConfig,
            revision: payloadConfig.enhanceConfig.imageRevision,
          ),
        ImageHandoffAction.directorTools => (
            config: payloadConfig.directorToolConfig,
            revision: payloadConfig.directorToolConfig.imageRevision,
          ),
      };

  bool _targetImageStateMatches(
    ImageHandoffAction action,
    _TargetImageState expected,
  ) {
    final current = _targetImageState(action);
    return identical(current.config, expected.config) &&
        current.revision == expected.revision;
  }

  void _finishSuperseded(int requestGeneration) {
    if (requestGeneration != _generation) return;
    _phase = ImageHandoffPhase.idle;
    _error = null;
    notifyListeners();
  }
}
