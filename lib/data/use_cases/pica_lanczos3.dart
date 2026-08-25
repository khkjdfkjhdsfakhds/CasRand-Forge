import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

// Derived from Pica (https://github.com/nodeca/pica).
// Copyright (c) 2014 Vitaly Puzrin, Alex Kocharin.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

/// Pixel-compatible Dart port of Pica's fixed-point Lanczos3 resize path.
///
/// Pica is MIT-licensed: https://github.com/nodeca/pica. The filter table and
/// two-pass convolution arithmetic intentionally mirror its JavaScript math,
/// including Float32/Int16 quantization and signed 32-bit accumulation.
img.Image picaLanczos3Resize(
  img.Image source, {
  required int width,
  required int height,
}) {
  final sourceBytes = Uint8List(source.width * source.height * 4);
  var offset = 0;
  var hasAlpha = false;
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final pixel = source.getPixel(x, y);
      sourceBytes[offset++] = pixel.r.toInt();
      sourceBytes[offset++] = pixel.g.toInt();
      sourceBytes[offset++] = pixel.b.toInt();
      final alpha = pixel.a.toInt();
      sourceBytes[offset++] = alpha;
      hasAlpha = hasAlpha || alpha != 255;
    }
  }

  final filtersX = _createFilters(source.width, width, width / source.width);
  final filtersY =
      _createFilters(source.height, height, height / source.height);
  final temporary = Uint16List(width * source.height * 4);
  final destination = Uint8List(width * height * 4);
  if (hasAlpha) {
    _convolveHorizontalWithPremultiply(
      sourceBytes,
      temporary,
      source.width,
      source.height,
      width,
      filtersX,
    );
    _convolveVerticalWithPremultiply(
      temporary,
      destination,
      source.height,
      width,
      height,
      filtersY,
    );
  } else {
    _convolveHorizontal(
      sourceBytes,
      temporary,
      source.width,
      source.height,
      width,
      filtersX,
    );
    _convolveVertical(
      temporary,
      destination,
      source.height,
      width,
      height,
      filtersY,
    );
    for (var index = 3; index < destination.length; index += 4) {
      destination[index] = 255;
    }
  }

  final output = img.Image(width: width, height: height, numChannels: 4);
  offset = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      output.setPixelRgba(
        x,
        y,
        destination[offset++],
        destination[offset++],
        destination[offset++],
        destination[offset++],
      );
    }
  }
  return output;
}

Int16List _createFilters(int sourceSize, int destinationSize, double scale) {
  final scaleInverted = 1 / scale;
  final scaleClamped = math.min(1.0, scale);
  final sourceWindow = 3 / scaleClamped;
  final maxFilterElementSize = ((sourceWindow + 1) * 2).floor();
  final packed = Int16List((maxFilterElementSize + 2) * destinationSize);
  var packedOffset = 0;

  for (var destinationPixel = 0;
      destinationPixel < destinationSize;
      destinationPixel++) {
    final sourcePixel = (destinationPixel + 0.5) * scaleInverted;
    final sourceFirst = math.max(0, (sourcePixel - sourceWindow).floor());
    final sourceLast =
        math.min(sourceSize - 1, (sourcePixel + sourceWindow).ceil());
    final filterElementSize = sourceLast - sourceFirst + 1;
    final floatFilter = Float32List(filterElementSize);
    final fixedFilter = Int16List(filterElementSize);
    var total = 0.0;
    for (var source = sourceFirst, index = 0;
        source <= sourceLast;
        source++, index++) {
      final value = _lanczos3(((source + 0.5) - sourcePixel) * scaleClamped);
      total += value;
      floatFilter[index] = value;
    }

    var filterTotal = 0.0;
    for (var index = 0; index < floatFilter.length; index++) {
      final value = floatFilter[index] / total;
      filterTotal += value;
      fixedFilter[index] = _toFixedPoint(value);
    }
    // This index is intentionally destinationSize / 2: it preserves the
    // observable Pica implementation, including its out-of-range no-op.
    final compensationIndex = destinationSize >> 1;
    if (compensationIndex < fixedFilter.length) {
      fixedFilter[compensationIndex] =
          fixedFilter[compensationIndex] + _toFixedPoint(1 - filterTotal);
    }

    var firstNonZero = 0;
    while (
        firstNonZero < fixedFilter.length && fixedFilter[firstNonZero] == 0) {
      firstNonZero++;
    }
    if (firstNonZero == fixedFilter.length) {
      packed[packedOffset++] = 0;
      packed[packedOffset++] = 0;
      continue;
    }
    var lastNonZero = fixedFilter.length - 1;
    while (lastNonZero > 0 && fixedFilter[lastNonZero] == 0) {
      lastNonZero--;
    }
    final filterSize = lastNonZero - firstNonZero + 1;
    packed[packedOffset++] = sourceFirst + firstNonZero;
    packed[packedOffset++] = filterSize;
    for (var index = firstNonZero; index <= lastNonZero; index++) {
      packed[packedOffset++] = fixedFilter[index];
    }
  }
  return packed;
}

double _lanczos3(double value) {
  final x = value.abs();
  if (x >= 3) return 0;
  if (x < 1.19209290e-7) return 1;
  final xPi = x * math.pi;
  return (math.sin(xPi) / xPi) * math.sin(xPi / 3) / (xPi / 3);
}

int _toFixedPoint(double value) => _javascriptRound(value * 16383);

int _javascriptRound(double value) => (value + 0.5).floor();

int _int32(int value) => value.toSigned(32);

int _clampTo8(int value) => value < 0 ? 0 : (value > 255 ? 255 : value);

int _clampNegative(int value) => value < 0 ? 0 : value;

void _convolveHorizontal(
  Uint8List source,
  Uint16List destination,
  int sourceWidth,
  int sourceHeight,
  int destinationWidth,
  Int16List filters,
) {
  var sourceOffset = 0;
  var destinationOffset = 0;
  for (var sourceY = 0; sourceY < sourceHeight; sourceY++) {
    var filterOffset = 0;
    for (var destinationX = 0;
        destinationX < destinationWidth;
        destinationX++) {
      final filterShift = filters[filterOffset++];
      var filterSize = filters[filterOffset++];
      var sourcePointer = sourceOffset + filterShift * 4;
      var red = 0;
      var green = 0;
      var blue = 0;
      var alpha = 0;
      while (filterSize-- > 0) {
        final filterValue = filters[filterOffset++];
        alpha = _int32(alpha + filterValue * source[sourcePointer + 3]);
        blue = _int32(blue + filterValue * source[sourcePointer + 2]);
        green = _int32(green + filterValue * source[sourcePointer + 1]);
        red = _int32(red + filterValue * source[sourcePointer]);
        sourcePointer += 4;
      }
      destination[destinationOffset + 3] = _clampNegative(alpha >> 7);
      destination[destinationOffset + 2] = _clampNegative(blue >> 7);
      destination[destinationOffset + 1] = _clampNegative(green >> 7);
      destination[destinationOffset] = _clampNegative(red >> 7);
      destinationOffset += sourceHeight * 4;
    }
    destinationOffset = (sourceY + 1) * 4;
    sourceOffset = (sourceY + 1) * sourceWidth * 4;
  }
}

void _convolveVertical(
  Uint16List source,
  Uint8List destination,
  int sourceWidth,
  int sourceHeight,
  int destinationWidth,
  Int16List filters,
) {
  var sourceOffset = 0;
  var destinationOffset = 0;
  for (var sourceY = 0; sourceY < sourceHeight; sourceY++) {
    var filterOffset = 0;
    for (var destinationX = 0;
        destinationX < destinationWidth;
        destinationX++) {
      final filterShift = filters[filterOffset++];
      var filterSize = filters[filterOffset++];
      var sourcePointer = sourceOffset + filterShift * 4;
      var red = 0;
      var green = 0;
      var blue = 0;
      var alpha = 0;
      while (filterSize-- > 0) {
        final filterValue = filters[filterOffset++];
        alpha = _int32(alpha + filterValue * source[sourcePointer + 3]);
        blue = _int32(blue + filterValue * source[sourcePointer + 2]);
        green = _int32(green + filterValue * source[sourcePointer + 1]);
        red = _int32(red + filterValue * source[sourcePointer]);
        sourcePointer += 4;
      }
      red >>= 7;
      green >>= 7;
      blue >>= 7;
      alpha >>= 7;
      destination[destinationOffset + 3] = _clampTo8((alpha + (1 << 13)) >> 14);
      destination[destinationOffset + 2] = _clampTo8((blue + (1 << 13)) >> 14);
      destination[destinationOffset + 1] = _clampTo8((green + (1 << 13)) >> 14);
      destination[destinationOffset] = _clampTo8((red + (1 << 13)) >> 14);
      destinationOffset += sourceHeight * 4;
    }
    destinationOffset = (sourceY + 1) * 4;
    sourceOffset = (sourceY + 1) * sourceWidth * 4;
  }
}

void _convolveHorizontalWithPremultiply(
  Uint8List source,
  Uint16List destination,
  int sourceWidth,
  int sourceHeight,
  int destinationWidth,
  Int16List filters,
) {
  var sourceOffset = 0;
  var destinationOffset = 0;
  for (var sourceY = 0; sourceY < sourceHeight; sourceY++) {
    var filterOffset = 0;
    for (var destinationX = 0;
        destinationX < destinationWidth;
        destinationX++) {
      final filterShift = filters[filterOffset++];
      var filterSize = filters[filterOffset++];
      var sourcePointer = sourceOffset + filterShift * 4;
      var red = 0;
      var green = 0;
      var blue = 0;
      var alpha = 0;
      while (filterSize-- > 0) {
        final filterValue = filters[filterOffset++];
        final sourceAlpha = source[sourcePointer + 3];
        alpha = _int32(alpha + filterValue * sourceAlpha);
        blue = _int32(
          blue + filterValue * source[sourcePointer + 2] * sourceAlpha,
        );
        green = _int32(
          green + filterValue * source[sourcePointer + 1] * sourceAlpha,
        );
        red = _int32(
          red + filterValue * source[sourcePointer] * sourceAlpha,
        );
        sourcePointer += 4;
      }
      blue = _int32(blue ~/ 255);
      green = _int32(green ~/ 255);
      red = _int32(red ~/ 255);
      destination[destinationOffset + 3] = _clampNegative(alpha >> 7);
      destination[destinationOffset + 2] = _clampNegative(blue >> 7);
      destination[destinationOffset + 1] = _clampNegative(green >> 7);
      destination[destinationOffset] = _clampNegative(red >> 7);
      destinationOffset += sourceHeight * 4;
    }
    destinationOffset = (sourceY + 1) * 4;
    sourceOffset = (sourceY + 1) * sourceWidth * 4;
  }
}

void _convolveVerticalWithPremultiply(
  Uint16List source,
  Uint8List destination,
  int sourceWidth,
  int sourceHeight,
  int destinationWidth,
  Int16List filters,
) {
  var sourceOffset = 0;
  var destinationOffset = 0;
  for (var sourceY = 0; sourceY < sourceHeight; sourceY++) {
    var filterOffset = 0;
    for (var destinationX = 0;
        destinationX < destinationWidth;
        destinationX++) {
      final filterShift = filters[filterOffset++];
      var filterSize = filters[filterOffset++];
      var sourcePointer = sourceOffset + filterShift * 4;
      var red = 0;
      var green = 0;
      var blue = 0;
      var alpha = 0;
      while (filterSize-- > 0) {
        final filterValue = filters[filterOffset++];
        alpha = _int32(alpha + filterValue * source[sourcePointer + 3]);
        blue = _int32(blue + filterValue * source[sourcePointer + 2]);
        green = _int32(green + filterValue * source[sourcePointer + 1]);
        red = _int32(red + filterValue * source[sourcePointer]);
        sourcePointer += 4;
      }
      red >>= 7;
      green >>= 7;
      blue >>= 7;
      alpha >>= 7;
      alpha = _clampTo8((alpha + (1 << 13)) >> 14);
      if (alpha > 0) {
        red = _int32(red * 255 ~/ alpha);
        green = _int32(green * 255 ~/ alpha);
        blue = _int32(blue * 255 ~/ alpha);
      }
      destination[destinationOffset + 3] = alpha;
      destination[destinationOffset + 2] = _clampTo8((blue + (1 << 13)) >> 14);
      destination[destinationOffset + 1] = _clampTo8((green + (1 << 13)) >> 14);
      destination[destinationOffset] = _clampTo8((red + (1 << 13)) >> 14);
      destinationOffset += sourceHeight * 4;
    }
    destinationOffset = (sourceY + 1) * 4;
    sourceOffset = (sourceY + 1) * sourceWidth * 4;
  }
}
