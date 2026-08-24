import 'dart:typed_data';

import 'package:nai_casrand/data/models/generation_performance_diagnostics.dart';

class ApiResponse {
  final String status;
  final Uint8List data;

  const ApiResponse({
    required this.status,
    required this.data,
  });
}

class ApiRequest {
  final String endpoint;
  final String proxy;
  final Map<String, String> headers;
  final Map<String, dynamic> payload;
  final GenerationDiagnosticContext? diagnosticContext;

  const ApiRequest({
    required this.endpoint,
    required this.proxy,
    required this.headers,
    required this.payload,
    this.diagnosticContext,
  });
}
