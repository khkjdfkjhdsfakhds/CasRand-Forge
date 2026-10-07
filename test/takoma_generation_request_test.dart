import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/use_cases/takoma_generation_request_use_case.dart';

String _pngBase64(int seed) => base64Encode(
      Uint8List.fromList(List<int>.generate(16, (index) => (seed + index) % 256)),
    );

void main() {
  test('plain txt2img keeps the JSON body', () {
    final payload = <String, dynamic>{
      'action': 'generate',
      'parameters': <String, dynamic>{'width': 832, 'height': 1216},
    };

    expect(TakomaGenerationRequestUseCase.build(payload), isNull);
  });

  test('img2img moves the source image into an image part', () {
    final imageB64 = _pngBase64(0);
    final payload = <String, dynamic>{
      'action': 'img2img',
      'parameters': <String, dynamic>{'width': 512, 'height': 512, 'image': imageB64},
    };

    final request = TakomaGenerationRequestUseCase.build(payload)!;
    expect(request.multipart.parts.map((part) => part.field), ['image', 'request']);
    expect(request.multipart.parts.first.bytes, base64Decode(imageB64));
    expect(request.multipart.parts.last.contentType, 'application/json');
    final body =
        jsonDecode(utf8.decode(request.multipart.parts.last.bytes)) as Map<String, dynamic>;
    expect((body['parameters'] as Map<String, dynamic>)['image'], 'image');
    // The original payload keeps the inline image for local bookkeeping.
    expect((payload['parameters'] as Map<String, dynamic>)['image'], imageB64);
  });

  test('infill sends both the base image and the mask as parts', () {
    final payload = <String, dynamic>{
      'action': 'infill',
      'parameters': <String, dynamic>{
        'image': _pngBase64(1),
        'mask': _pngBase64(2),
      },
    };

    final request = TakomaGenerationRequestUseCase.build(payload)!;
    expect(request.multipart.parts.map((part) => part.field), ['image', 'mask', 'request']);
    final body =
        jsonDecode(utf8.decode(request.multipart.parts.last.bytes)) as Map<String, dynamic>;
    final parameters = body['parameters'] as Map<String, dynamic>;
    expect(parameters['image'], 'image');
    expect(parameters['mask'], 'mask');
  });

  test('precise reference images become indexed parts', () {
    final payload = <String, dynamic>{
      'action': 'generate',
      'parameters': <String, dynamic>{
        'director_reference_images': [_pngBase64(3), _pngBase64(4)],
        'director_reference_strength_values': [1.0, 0.6],
      },
    };

    final request = TakomaGenerationRequestUseCase.build(payload)!;
    expect(
      request.multipart.parts.map((part) => part.field),
      ['director_ref0', 'director_ref1', 'request'],
    );
    final body =
        jsonDecode(utf8.decode(request.multipart.parts.last.bytes)) as Map<String, dynamic>;
    expect(
      (body['parameters'] as Map<String, dynamic>)['director_reference_images'],
      ['director_ref0', 'director_ref1'],
    );
  });

  test('director tools send their flat image field as a part', () {
    final imageB64 = _pngBase64(5);
    final payload = <String, dynamic>{
      'req_type': 'bg-removal',
      'width': 512,
      'height': 512,
      'image': imageB64,
    };

    final request = TakomaGenerationRequestUseCase.build(payload)!;
    expect(request.multipart.parts.map((part) => part.field), ['image', 'request']);
    final body =
        jsonDecode(utf8.decode(request.multipart.parts.last.bytes)) as Map<String, dynamic>;
    expect(body['image'], 'image');
    expect(body['req_type'], 'bg-removal');
  });

  test('data url images keep their declared content type', () {
    final payload = <String, dynamic>{
      'action': 'img2img',
      'parameters': <String, dynamic>{
        'image': 'data:image/jpeg;base64,${_pngBase64(6)}',
      },
    };

    final request = TakomaGenerationRequestUseCase.build(payload)!;
    expect(request.multipart.parts.first.contentType, 'image/jpeg');
    expect(request.multipart.parts.first.bytes, base64Decode(_pngBase64(6)));
  });

  test('undecodable image data is left alone instead of being dropped', () {
    final payload = <String, dynamic>{
      'action': 'img2img',
      'parameters': <String, dynamic>{'image': 'not base64 !!!'},
    };

    expect(TakomaGenerationRequestUseCase.build(payload), isNull);
  });
}
