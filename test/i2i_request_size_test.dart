import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/use_cases/i2i_request_size.dart';

void main() {
  test('automatic mode keeps a small source near its original size', () {
    expect(
      automaticI2iRequestSize(500, 300),
      const GenerationSize(width: 512, height: 320),
    );
  });

  test('automatic mode fits a large portrait inside the normal area', () {
    final size = automaticI2iRequestSize(2000, 3000);
    expect(size.width % 64, 0);
    expect(size.height % 64, 0);
    expect(size.width * size.height, lessThanOrEqualTo(novelAiNormalMaxPixels));
    expect(size.width / size.height, closeTo(2 / 3, 0.06));
  });

  test('original mode may exceed normal area but never generation area', () {
    final size = originalI2iRequestSize(2000, 3000);
    expect(size.width % 64, 0);
    expect(size.height % 64, 0);
    expect(size.width * size.height, greaterThan(novelAiNormalMaxPixels));
    expect(
      size.width * size.height,
      lessThanOrEqualTo(novelAiGenerationMaxPixels),
    );
  });

  test('manual size is also forced onto the grid and under the area limit', () {
    final normal = manualI2iRequestSize(900, 1250);
    expect(normal, const GenerationSize(width: 896, height: 1280));

    final oversized = manualI2iRequestSize(4000, 4000);
    expect(oversized.width % 64, 0);
    expect(oversized.height % 64, 0);
    expect(
      oversized.width * oversized.height,
      lessThanOrEqualTo(novelAiGenerationMaxPixels),
    );
    expect(oversized.width / oversized.height, closeTo(1, 0.001));
  });

  test('extreme aspect ratios remain valid without a per-side clamp', () {
    final size = originalI2iRequestSize(6000, 500);
    expect(size.width % 64, 0);
    expect(size.height % 64, 0);
    expect(
      size.width * size.height,
      lessThanOrEqualTo(novelAiGenerationMaxPixels),
    );
    expect(size.width, greaterThan(1728));
  });
}
