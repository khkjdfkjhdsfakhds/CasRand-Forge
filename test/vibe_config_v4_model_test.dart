import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';

import 'vibe_test_utils.dart';

void main() {
  const v45Model = 'nai-diffusion-4-5-full';
  const v4Model = 'nai-diffusion-4-full';

  test('normal PNG is accepted as an image-backed Vibe source', () {
    final png = makeTestPng();
    final config = VibeConfigV4.fromPngBytes(
      'reference.png',
      png,
      0.6,
      model: v45Model,
    );

    expect(config.fileName, 'reference.png');
    expect(config.imageBytes, png);
    expect(config.referenceStrength, 0.6);
    expect(config.informationExtracted, 0.7);
    expect(config.canEncode, isTrue);
    expect(config.hasAnyEncoding, isFalse);
    expect(config.encodingFor(v45Model), isNull);
    expect(config.vibeB64, isEmpty);
  });

  test('PNG iTXt Vibe encoding is imported for the current model', () {
    final png = embedVibeEncodingInPng(makeTestPng(), 'embedded-encoding');
    final config = VibeConfigV4.fromImageBytes(
      'embedded.png',
      png,
      0.6,
      informationExtracted: 0.7,
      model: v45Model,
    );

    expect(config.encodingFor(v45Model), 'embedded-encoding');
    expect(config.needsEncoding(v45Model), isFalse);
    expect(config.canEncode, isTrue);
  });

  test('.naiv4vibe imports image, strength, information, and model caches', () {
    final json = <String, dynamic>{
      'name': 'Imported Vibe',
      'type': 'image',
      'image': base64Encode(makeTestPng()),
      'importInfo': {
        'model': v45Model,
        'strength': 0.6,
        'information_extracted': 0.7,
      },
      'encodings': {
        'v4-5full': {
          'hash-v45': {
            'params': {'information_extracted': 0.7},
            'encoding': 'encoding-v45',
          },
        },
        'v4full': {
          'hash-v4': {
            'params': {'information_extracted': 0.35},
            'encoding': 'encoding-v4',
          },
        },
      },
    };

    final config = VibeConfigV4.fromNaiV4VibeJson(
      'source.naiv4vibe',
      json,
      0.2,
    );

    expect(config.fileName, 'Imported Vibe');
    expect(config.referenceStrength, 0.6);
    expect(config.informationExtracted, 0.7);
    expect(config.canEncode, isTrue);
    expect(config.encodingFor(v45Model), 'encoding-v45');
    expect(
      config.encodingFor(v4Model, informationExtracted: 0.35),
      'encoding-v4',
    );
  });

  test('cache key changes with model and Information Extracted', () {
    final config = VibeConfigV4(
      fileName: 'reference.png',
      referenceStrength: 0.6,
      informationExtracted: 0.7,
      imageBytes: Uint8List.fromList([1, 2, 3]),
    );
    config.cacheEncoding(
      model: v45Model,
      informationExtracted: 0.7,
      encoding: 'cached-v45-07',
    );

    expect(config.encodingFor(v45Model), 'cached-v45-07');
    config.informationExtracted = 0.8;
    expect(config.encodingFor(v45Model), isNull);
    expect(config.encodingFor(v4Model), isNull);

    config.informationExtracted = 0.7;
    expect(config.encodingFor(v45Model), 'cached-v45-07');
  });

  test('encoded-only Vibe reports a model mismatch without an image fallback',
      () {
    final config = VibeConfigV4.fromNaiV4VibeJson(
      'encoded-only.naiv4vibe',
      {
        'type': 'encoding',
        'importInfo': {
          'model': v45Model,
          'information_extracted': 0.7,
        },
        'encodings': {
          'v4-5full': {
            'hash': {
              'params': {'information_extracted': 0.7},
              'encoding': 'v45-only',
            },
          },
        },
      },
      0.6,
    );

    expect(config.canEncode, isFalse);
    expect(config.encodingFor(v45Model), 'v45-only');
    expect(config.encodingFor(v4Model), isNull);
  });
}
