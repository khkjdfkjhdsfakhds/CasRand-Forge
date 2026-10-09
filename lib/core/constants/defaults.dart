import '../../data/models/generation_size.dart';

const defaultUC =
    'lowres, artistic error, film grain, scan artifacts, worst quality, bad quality, jpeg artifacts, very displeasing, chromatic aberration, dithering, halftone, screentone, multiple views, logo, too many watermarks, negative space, blank page';
const defaultFilenamePrefix = 'NAI-generated';
const defaultSizes = [
  GenerationSize(width: 832, height: 1216),
  GenerationSize(width: 1216, height: 832),
  GenerationSize(width: 1024, height: 1024),
  GenerationSize(width: 1024, height: 1536),
  GenerationSize(width: 1536, height: 1024),
  GenerationSize(width: 1472, height: 1472),
  GenerationSize(width: 768, height: 1344),
  GenerationSize(width: 1344, height: 768),
];
