import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';

enum BatchToolKind { enhance, director }

/// A prepared, session-only source. Repeated tasks never consume prior outputs.
/// No credentials or mutable source configuration are retained here.
class BatchToolSnapshot {
  BatchToolSnapshot.enhance({
    required this.enhanceBatch,
    required ParamConfig parameters,
    required this.upscale,
    required this.outputWidth,
    required this.outputHeight,
  })  : kind = BatchToolKind.enhance,
        _parameters = parameters.toJson(),
        directorPayload = const {},
        label = upscale ? 'Enhance Max' : 'Enhance';

  BatchToolSnapshot.director({
    required Map<String, dynamic> payload,
    required this.label,
    required this.outputWidth,
    required this.outputHeight,
  })  : kind = BatchToolKind.director,
        directorPayload = Map.unmodifiable(payload),
        enhanceBatch = null,
        _parameters = const {},
        upscale = false;

  final BatchToolKind kind;
  final I2iRequestBatch? enhanceBatch;
  final Map<String, dynamic> _parameters;
  final Map<String, dynamic> directorPayload;
  final String label;
  final bool upscale;
  final int outputWidth;
  final int outputHeight;
  ParamConfig get parameters => ParamConfig.fromJson(_parameters);
  String get directorType => directorPayload['req_type'] as String? ?? '';
  bool get usesPrompt =>
      kind == BatchToolKind.enhance ||
      directorType == 'colorize' ||
      directorType == 'emotion';
  String get summary => '$label · $outputWidth×$outputHeight';
}
