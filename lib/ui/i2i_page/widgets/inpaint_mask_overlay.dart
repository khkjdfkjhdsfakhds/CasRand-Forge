import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Maps a canonical black/white mask to the translucent red used throughout
/// the inpainting UI. The red channel becomes alpha, so black stays invisible.
const ColorFilter inpaintMaskRedColorFilter = ColorFilter.matrix(<double>[
  0,
  0,
  0,
  0,
  229,
  0,
  0,
  0,
  0,
  57,
  0,
  0,
  0,
  0,
  53,
  1,
  0,
  0,
  0,
  0,
]);

class InpaintMaskOverlay extends StatelessWidget {
  final Uint8List maskBytes;
  final BoxFit fit;
  final double opacity;

  const InpaintMaskOverlay({
    super.key,
    required this.maskBytes,
    this.fit = BoxFit.fill,
    this.opacity = 0.54,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: ColorFiltered(
          colorFilter: inpaintMaskRedColorFilter,
          child: Image.memory(
            maskBytes,
            fit: fit,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}
