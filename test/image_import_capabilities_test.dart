import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/image_import_capabilities.dart';

void main() {
  test('image import actions follow the active NovelAI model family', () {
    expect(
      ImageImportCapabilities.forModel('nai-diffusion-5-full').actions,
      {ImageImportAction.imageToImage},
    );
    expect(
      ImageImportCapabilities.forModel('nai-diffusion-4-5-full').actions,
      {
        ImageImportAction.imageToImage,
        ImageImportAction.vibeTransfer,
        ImageImportAction.preciseReference,
      },
    );
    expect(
      ImageImportCapabilities.forModel('nai-diffusion-4-full').actions,
      {
        ImageImportAction.imageToImage,
        ImageImportAction.vibeTransfer,
      },
    );
    expect(
      ImageImportCapabilities.forModel('nai-diffusion-3').actions,
      {
        ImageImportAction.imageToImage,
        ImageImportAction.vibeTransfer,
      },
    );
  });
}
