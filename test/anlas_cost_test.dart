import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';

void main() {
  test('matches the measured cost of a real request', () {
    // Measured live: 832x1216 at 4 steps cost exactly 6 Anlas on a non-Opus
    // account.
    final cost = estimateAnlasCost(width: 832, height: 1216, steps: 4);
    expect(cost.anlas, 6);
    expect(cost.perImageAnlas, 6);
    expect(cost.isFreeUnderOpus, isFalse);
  });

  test('opus covers one image inside the free window', () {
    final cost = estimateAnlasCost(
      width: 832,
      height: 1216,
      steps: 28,
      tier: opusTier,
      subscriptionActive: true,
    );
    expect(cost.anlas, 0);
    expect(cost.isFreeUnderOpus, isTrue);
    // The per-image price is still known even when it is waived.
    expect(cost.perImageAnlas, greaterThan(0));
  });

  test('an expired or unverified Opus tier is never treated as free', () {
    final cost = estimateAnlasCost(
      width: 832,
      height: 1216,
      steps: 28,
      tier: opusTier,
      subscriptionActive: false,
    );
    expect(cost.anlas, cost.perImageAnlas);
    expect(cost.isFreeUnderOpus, isFalse);
  });

  test('opus only waives one image per request', () {
    final cost = estimateAnlasCost(
      width: 832,
      height: 1216,
      steps: 28,
      nSamples: 4,
      tier: opusTier,
      subscriptionActive: true,
    );
    final single = estimateAnlasCost(
      width: 832,
      height: 1216,
      steps: 28,
      tier: opusTier,
      subscriptionActive: true,
    );
    expect(cost.anlas, single.perImageAnlas * 3);
    expect(cost.isFreeUnderOpus, isFalse);
  });

  test('the opus free window is bounded by area and steps', () {
    expect(fitsOpusFreeWindow(width: 1024, height: 1024, steps: 28), isTrue);
    expect(fitsOpusFreeWindow(width: 832, height: 1216, steps: 28), isTrue);
    // One step over, or one pixel tier up, and the allowance is gone.
    expect(fitsOpusFreeWindow(width: 1024, height: 1024, steps: 29), isFalse);
    expect(fitsOpusFreeWindow(width: 1024, height: 1536, steps: 28), isFalse);

    final large = estimateAnlasCost(
      width: 1024,
      height: 1536,
      steps: 28,
      tier: opusTier,
      subscriptionActive: true,
    );
    expect(large.anlas, greaterThan(0));
    expect(large.isFreeUnderOpus, isFalse);
  });

  test('img2img and infill scale the cost and never use Opus free allowance',
      () {
    final full = estimateAnlasCost(
      width: 1024,
      height: 1024,
      steps: 28,
      action: 'img2img',
      strength: 1.0,
    );
    final half = estimateAnlasCost(
      width: 1024,
      height: 1024,
      steps: 28,
      action: 'img2img',
      strength: 0.5,
    );
    expect(half.anlas, lessThan(full.anlas));
    expect(half.anlas, (full.perImageAnlas * 0.5).ceil());

    final infill = estimateAnlasCost(
      width: 1024,
      height: 1024,
      steps: 28,
      action: 'infill',
      strength: 0.5,
    );
    expect(infill.anlas, half.anlas);

    final opusImg2img = estimateAnlasCost(
      width: 1024,
      height: 1024,
      steps: 28,
      action: 'img2img',
      strength: 0.5,
      tier: opusTier,
      subscriptionActive: true,
    );
    expect(opusImg2img.anlas, half.anlas);
    expect(opusImg2img.isFreeUnderOpus, isFalse);
  });

  test('a plain generate ignores strength', () {
    final a = estimateAnlasCost(width: 1024, height: 1024, steps: 28);
    final b = estimateAnlasCost(
      width: 1024,
      height: 1024,
      steps: 28,
      strength: 0.2,
    );
    expect(a.anlas, b.anlas);
  });

  test('cost never drops below the two-Anlas floor', () {
    final cost = estimateAnlasCost(
      width: 64,
      height: 64,
      steps: 1,
      action: 'img2img',
      strength: 0.01,
    );
    expect(cost.perImageAnlas, 2);
  });

  test('precise references and extra vibes add a surcharge', () {
    final base = estimateAnlasCost(width: 1024, height: 1024, steps: 28);
    final withRefs = estimateAnlasCost(
      width: 1024,
      height: 1024,
      steps: 28,
      preciseReferenceCount: 2,
    );
    expect(withRefs.anlas, base.anlas + 2 * preciseReferenceAnlas);

    final withVibes = estimateAnlasCost(
      width: 1024,
      height: 1024,
      steps: 28,
      vibeCount: 6,
    );
    expect(withVibes.anlas, base.anlas + 2 * extraVibeAnlas);

    // The first four vibes are included.
    final freeVibes = estimateAnlasCost(
      width: 1024,
      height: 1024,
      steps: 28,
      vibeCount: 4,
    );
    expect(freeVibes.anlas, base.anlas);
  });

  test('a split inpaint batch is paid even on active Opus', () {
    final cost = estimateBatchAnlasCost(
      tiles: List.filled(4, (width: 768, height: 1344)),
      steps: 28,
      strength: 0.8,
      tier: opusTier,
      subscriptionActive: true,
    );
    expect(cost.anlas, greaterThan(0));
    expect(cost.isFreeUnderOpus, isFalse);
  });

  test('a split batch without Opus costs every tile', () {
    final single = estimateAnlasCost(
      width: 768,
      height: 1344,
      steps: 28,
      action: 'infill',
      strength: 0.8,
    );
    final cost = estimateBatchAnlasCost(
      tiles: List.filled(4, (width: 768, height: 1344)),
      steps: 28,
      strength: 0.8,
    );
    expect(cost.anlas, single.anlas * 4);
    expect(cost.isFreeUnderOpus, isFalse);
  });

  test('a tile outside the free window makes the batch cost', () {
    final cost = estimateBatchAnlasCost(
      tiles: const [
        (width: 768, height: 1344),
        (width: 1472, height: 1472),
      ],
      steps: 28,
      tier: opusTier,
      subscriptionActive: true,
    );
    expect(cost.anlas, greaterThan(0));
    expect(cost.isFreeUnderOpus, isFalse);
  });

  group('director tools', () {
    test('matches the measured background-removal prices', () {
      // Measured live; there is no published formula.
      expect(
        estimateDirectorToolAnlas(tool: 'bg-removal', width: 384, height: 384),
        14,
      );
      expect(
        estimateDirectorToolAnlas(tool: 'bg-removal', width: 512, height: 512),
        20,
      );
      expect(
        estimateDirectorToolAnlas(
            tool: 'bg-removal', width: 1024, height: 1024),
        65,
      );
    });

    test('matches the measured price of the other tools', () {
      for (final tool in ['lineart', 'emotion', 'declutter-keep-bubbles']) {
        expect(
          estimateDirectorToolAnlas(tool: tool, width: 512, height: 512),
          5,
          reason: '$tool at 512',
        );
      }
      expect(
        estimateDirectorToolAnlas(tool: 'lineart', width: 1024, height: 1024),
        20,
      );
    });

    test('background removal always costs more than the other tools', () {
      for (final size in [384, 512, 768, 1024, 1472]) {
        final bg = estimateDirectorToolAnlas(
            tool: 'bg-removal', width: size, height: size);
        final other = estimateDirectorToolAnlas(
            tool: 'lineart', width: size, height: size);
        expect(bg, greaterThan(other), reason: 'at $size');
      }
    });

    test('cost scales with pixels and is never zero', () {
      expect(
        estimateDirectorToolAnlas(tool: 'lineart', width: 1024, height: 1024),
        greaterThan(
          estimateDirectorToolAnlas(tool: 'lineart', width: 512, height: 512),
        ),
      );
      expect(
        estimateDirectorToolAnlas(tool: 'lineart', width: 8, height: 8),
        greaterThanOrEqualTo(1),
      );
      expect(
        estimateDirectorToolAnlas(tool: 'lineart', width: 0, height: 0),
        0,
      );
    });
  });
}
