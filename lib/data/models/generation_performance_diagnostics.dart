enum GenerationPerformanceStage {
  preparationStarted,
  preparationCompleted,
  cacheReady,
  requestStarted,
  responseStarted,
  responseCompleted,
  requestCompleted,
  resultProcessingStarted,
  resultProcessingCompleted,
  failed,
}

typedef GenerationPerformanceObserver = void Function(
  GenerationPerformanceEvent event,
);

/// Content-free timing information for one generation request.
///
/// The type intentionally has no fields capable of carrying credentials,
/// prompts, image data, filenames, local paths, or proxy values.
class GenerationPerformanceEvent {
  final String correlationId;
  final GenerationPerformanceStage stage;
  final int? elapsedMicroseconds;
  final int? normalizedImageBytes;
  final int? requestBodyBytes;
  final bool? cacheHit;
  final int? statusCode;
  final String? errorClass;

  const GenerationPerformanceEvent({
    required this.correlationId,
    required this.stage,
    this.elapsedMicroseconds,
    this.normalizedImageBytes,
    this.requestBodyBytes,
    this.cacheHit,
    this.statusCode,
    this.errorClass,
  });

  Map<String, Object> toJson() => {
        'correlation_id': correlationId,
        'stage': stage.name,
        if (elapsedMicroseconds != null) 'elapsed_us': elapsedMicroseconds!,
        if (normalizedImageBytes != null)
          'normalized_image_bytes': normalizedImageBytes!,
        if (requestBodyBytes != null) 'request_body_bytes': requestBodyBytes!,
        if (cacheHit != null) 'cache_hit': cacheHit!,
        if (statusCode != null) 'status_code': statusCode!,
        if (errorClass != null) 'error_class': errorClass!,
      };
}

class GenerationDiagnosticContext {
  final String correlationId;
  final int preparationMicroseconds;
  final int normalizedImageBytes;

  const GenerationDiagnosticContext({
    required this.correlationId,
    required this.preparationMicroseconds,
    required this.normalizedImageBytes,
  });
}
