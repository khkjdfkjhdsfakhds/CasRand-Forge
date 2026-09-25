import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_image_paste_area.dart';
import 'package:nai_casrand/ui/navigation/view_models/metadata_drop_area_viewmodel.dart';
import 'package:nai_casrand/ui/navigation/widgets/metadata_drop_area.dart';

/// Unifies drag-and-drop ([MetadataDropArea]) and keyboard paste ([GenerationImagePasteArea])
/// for importing images and metadata across pages that do not host dedicated image or
/// text input controls.
class ImageImportArea extends StatefulWidget {
  final Widget child;
  final MetadataDropAreaViewmodel? viewmodel;
  final bool ignoreWhenTextEditing;

  const ImageImportArea({
    super.key,
    required this.child,
    this.viewmodel,
    this.ignoreWhenTextEditing = true,
  });

  @override
  State<ImageImportArea> createState() => _ImageImportAreaState();
}

class _ImageImportAreaState extends State<ImageImportArea> {
  late final MetadataDropAreaViewmodel _viewmodel =
      widget.viewmodel ?? MetadataDropAreaViewmodel();

  @override
  void dispose() {
    if (widget.viewmodel == null) {
      _viewmodel.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MetadataDropArea(
      viewmodel: _viewmodel,
      childBuilder: (context) => GenerationImagePasteArea(
        importViewmodel: _viewmodel,
        ignoreWhenTextEditing: widget.ignoreWhenTextEditing,
        child: widget.child,
      ),
    );
  }
}
