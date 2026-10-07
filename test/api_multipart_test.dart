import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/api_request.dart';

void main() {
  test('generated boundaries stay lowercase for relay compatibility', () {
    // Takoma answers HTTP 500 when a multipart boundary contains an uppercase
    // letter, so the generator must stay inside the lowercase base36 alphabet.
    for (var attempt = 0; attempt < 5; attempt++) {
      final body = ApiMultipartBody(parts: const []);
      expect(body.boundary, matches(RegExp(r'^[a-z0-9]+$')));
    }
  });

  test('encodes every part with CRLF headers and a trailing terminator', () {
    final body = ApiMultipartBody(
      boundary: 'testboundary',
      parts: [
        ApiMultipartPart(
          field: 'image',
          fileName: 'blob',
          contentType: 'image/png',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
        ApiMultipartPart(
          field: 'request',
          bytes: Uint8List.fromList([123, 125]),
        ),
      ],
    );

    final text = latin1.decode(body.encode());
    expect(
      text,
      '--testboundary\r\n'
      'Content-Disposition: form-data; name="image"; filename="blob"\r\n'
      'Content-Type: image/png\r\n'
      '\r\n'
      '\u0001\u0002\u0003\r\n'
      '--testboundary\r\n'
      'Content-Disposition: form-data; name="request"\r\n'
      'Content-Type: application/octet-stream\r\n'
      '\r\n'
      '{}\r\n'
      '--testboundary--\r\n',
    );
    expect(body.contentType, 'multipart/form-data; boundary=testboundary');
  });
}
