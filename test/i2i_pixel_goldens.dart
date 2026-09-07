import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:image/image.dart' as img;

// Provenance: captured from NovelAI's deployed preprocessing function in
// Chrome on 2026-09-07 (chunk 1052-61d45f60b6583648, module 54676).
// PNG carrier alpha is removed before Canvas decoding and Pica resizing.
// These hashes come from the website function, not the Dart implementation.
const sameSizeOpaqueRgbaSha256 =
    'f42ad0eb77261cced7eaaf42e6767def66672da4240a8f30aee9591273f0a478';
const sameSizeTransparentRgbaSha256 =
    'd941d6a21a0117d4576df984067f6a74dade651416315d382294e09716c2f99c';
const resizedLandscapeOpaqueRgbaSha256 =
    '33e2598d962108d0c4e713d8b3e7c2f16ceb9e7b9cbd40a9cc0964b27bc54f87';
const resizedLandscapeTransparentRgbaSha256 =
    '2d86912965fd72c6e3f7a84fd797f76332662f2182ff2225a774c25152bb9966';
const resizedPortraitOpaqueRgbaSha256 =
    '0624e57662df5e693df76bd09f50407082d2734e68034d2788f1810987e77126';
const resizedPortraitTransparentRgbaSha256 =
    '9f78993eca6d2621ab03b1ea19aba89155cfb8e54a7c9428413dfe513f4737a0';
const resizedOpaqueOnlyLandscapeRgbaSha256 =
    'bcc324973197cc431946c5814c10503656b819b191412c02490886d44942f86b';
const resizedOpaqueOnlyPortraitRgbaSha256 =
    '114342c38db6616edd388b0c06ee52df082a9298dd3621670eeb2f3bf3f07fc5';
const diagnosticResizedOpaqueRgbaSha256 =
    'ec4a8c2bd394158251bda9b451027fabea7d497924675b0b3449e95e3d2947c9';
const diagnosticResizedTransparentRgbaSha256 =
    '9fbdf8d634cbb56d21da304ceb842611bad126e18b499c0e6d7a0c47be613c86';

Uint8List stealthCarrierPng({bool transparentTail = true}) {
  const width = 16;
  const height = 8;
  const magic = 'stealth_pngcomp';
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(
        x,
        y,
        (x * 17 + y * 31) % 256,
        (x * 29 + y * 11) % 256,
        (x * 7 + y * 43) % 256,
        255,
      );
    }
  }
  final magicBytes = ascii.encode(magic);
  for (var bitIndex = 0; bitIndex < magicBytes.length * 8; bitIndex++) {
    final x = bitIndex ~/ height;
    final y = bitIndex % height;
    final bit = (magicBytes[bitIndex ~/ 8] >> (7 - bitIndex % 8)) & 1;
    final pixel = image.getPixel(x, y);
    image.setPixelRgba(x, y, pixel.r, pixel.g, pixel.b, 254 | bit);
  }
  // The first carrier bit is zero. PNG cleanup must preserve this RGB
  // before Canvas would round the alpha-254 red channel from 127 to 128.
  image.setPixelRgba(0, 0, 127, 87, 85, 254);
  if (transparentTail) {
    image.setPixelRgba(15, 0, 127, 87, 85, 1);
    image.setPixelRgba(15, 1, 1, 3, 5, 128);
    image.setPixelRgba(15, 2, 254, 128, 64, 64);
    image.setPixelRgba(15, 3, 12, 34, 56, 0);
  }
  return Uint8List.fromList(img.encodePng(image));
}

/// Larger deterministic diagnostic sample retained separately from the
/// minimum boundary fixture. Its 37x29 hashes were captured with the
/// deployed website preprocessing function, independently of this Dart code.
Uint8List diagnosticStealthCarrierPng() {
  const width = 64;
  const height = 48;
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(
        x,
        y,
        (x * 17 + y * 31) % 256,
        (x * 29 + y * 11) % 256,
        (x * 7 + y * 43) % 256,
        255,
      );
    }
  }
  final magicBytes = ascii.encode('stealth_pngcomp');
  for (var bitIndex = 0; bitIndex < magicBytes.length * 8; bitIndex++) {
    final x = bitIndex ~/ height;
    final y = bitIndex % height;
    final bit = (magicBytes[bitIndex ~/ 8] >> (7 - bitIndex % 8)) & 1;
    final pixel = image.getPixel(x, y);
    image.setPixelRgba(x, y, pixel.r, pixel.g, pixel.b, 254 | bit);
  }
  image.setPixelRgba(0, 0, 127, 87, 85, 254);
  image.setPixelRgba(63, 0, 127, 87, 85, 1);
  image.setPixelRgba(63, 1, 1, 3, 5, 128);
  image.setPixelRgba(63, 2, 254, 128, 64, 64);
  image.setPixelRgba(63, 47, 12, 34, 56, 0);
  image.setPixelRgba(0, 47, 33, 99, 201, 96);
  return Uint8List.fromList(img.encodePng(image));
}

String rgbaSha256(img.Image image) {
  final bytes = Uint8List(image.width * image.height * 4);
  var offset = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      bytes[offset++] = pixel.r.toInt();
      bytes[offset++] = pixel.g.toInt();
      bytes[offset++] = pixel.b.toInt();
      bytes[offset++] = pixel.a.toInt();
    }
  }
  return sha256.convert(bytes).toString();
}

String bytesSha256(List<int> bytes) => sha256.convert(bytes).toString();
