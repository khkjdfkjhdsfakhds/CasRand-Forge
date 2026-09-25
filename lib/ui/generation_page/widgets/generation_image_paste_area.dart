import 'dart:async';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/data/services/image_service.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/utils/platform_support.dart';
import 'package:nai_casrand/ui/navigation/view_models/metadata_drop_area_viewmodel.dart';
import 'package:nai_casrand/ui/navigation/widgets/image_import_dialog.dart';
import 'package:super_clipboard/super_clipboard.dart';

typedef ClipboardImageReader = Future<ImageImportCandidate?> Function();

/// Includes desktop TIFF/DIB conversion and image file-URI synthesis provided
/// by super_clipboard. Never resolves remote URLs from a text clipboard.
Future<ImageImportCandidate?> readGenerationClipboardImage() async {
  if (!supportsSuperNativeExtensions) return null;
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return null;
  final reader = await clipboard.read();
  for (final format in [
    Formats.png,
    Formats.jpeg,
    Formats.gif,
    Formats.webp,
    Formats.bmp
  ]) {
    if (!reader.canProvide(format)) continue;
    final result = Completer<ImageImportCandidate?>();
    final progress = reader.getFile(format, (file) async {
      try {
        final bytes = await file.readAll();
        result.complete(ImageImportCandidate(
            bytes: bytes, fileName: file.fileName ?? 'Clipboard image'));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }, onError: (error) {
      if (!result.isCompleted) result.completeError(error);
    });
    if (progress != null) return result.future;
  }
  return null;
}

/// Installed only while the generation page is mounted. An early focus handler
/// lets image paste work even over an editable control; ordinary text is handed
/// back to that control's own PasteTextIntent without changing its undo stack.
class GenerationImagePasteArea extends StatefulWidget {
  final Widget child;
  final ClipboardImageReader? clipboardReader;
  final ImageMetadataExtractor? metadataExtractor;
  final MetadataDropAreaViewmodel? importViewmodel;
  final bool ignoreWhenTextEditing;
  const GenerationImagePasteArea(
      {super.key,
      required this.child,
      this.clipboardReader,
      this.metadataExtractor,
      this.importViewmodel,
      this.ignoreWhenTextEditing = false});
  @override
  State<GenerationImagePasteArea> createState() =>
      _GenerationImagePasteAreaState();
}

class _GenerationImagePasteAreaState extends State<GenerationImagePasteArea> {
  late final _importViewmodel =
      widget.importViewmodel ?? MetadataDropAreaViewmodel();
  bool _reading = false;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    if (widget.importViewmodel == null) _importViewmodel.dispose();
    super.dispose();
  }

  bool _isTextEditingActive() {
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorStateOfType<EditableTextState>() != null ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (!mounted ||
        !TickerMode.valuesOf(context).enabled ||
        (!supportsSuperNativeExtensions && widget.clipboardReader == null) ||
        !(ModalRoute.of(context)?.isCurrent ?? true) ||
        _dialogOpen) {
      return KeyEventResult.ignored;
    }
    if (widget.ignoreWhenTextEditing && _isTextEditingActive()) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final paste = (event.logicalKey == LogicalKeyboardKey.keyV &&
            (keys.isMetaPressed || keys.isControlPressed) &&
            !keys.isShiftPressed &&
            !keys.isAltPressed) ||
        (event.logicalKey == LogicalKeyboardKey.insert &&
            keys.isShiftPressed &&
            !keys.isAltPressed);
    if (!paste || event is KeyUpEvent) return KeyEventResult.ignored;
    if (!_reading && event is KeyDownEvent) unawaited(_paste());
    return KeyEventResult.handled;
  }

  Future<void> _paste() async {
    final focus = FocusManager.instance.primaryFocus;
    final route = ModalRoute.of(context);
    setState(() => _reading = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final candidate =
          await (widget.clipboardReader ?? readGenerationClipboardImage)();
      if (!mounted || !(route?.isCurrent ?? true)) return;
      if (candidate == null) {
        final textData = await Clipboard.getData('text/plain');
        final focusContext = focus?.context;
        final editable =
            focusContext?.findAncestorStateOfType<EditableTextState>();
        if (focus == FocusManager.instance.primaryFocus &&
            editable != null &&
            textData?.text != null) {
          final value = editable.textEditingValue;
          final replacement = value.text.replaceRange(
              value.selection.start, value.selection.end, textData!.text!);
          final offset = value.selection.start + textData.text!.length;
          editable.userUpdateTextEditingValue(
              value.copyWith(
                  text: replacement,
                  selection: TextSelection.collapsed(offset: offset),
                  composing: TextRange.empty),
              SelectionChangedCause.keyboard);
        }
        return;
      }
      // Decode natively before opening the shared dialog so corrupt clipboard
      // bytes fail visibly rather than produce an unusable image preview.
      final codec = await ui.instantiateImageCodec(candidate.bytes);
      codec.dispose();
      if (!mounted || !(route?.isCurrent ?? true)) return;
      setState(() {
        _reading = false;
        _dialogOpen = true;
      });
      await showImageImportDialog(context,
          candidate: candidate,
          viewmodel: _importViewmodel,
          metadataLoader: () => ImageImportCandidate.fromImageBytes(
              bytes: candidate.bytes,
              fileName: candidate.fileName,
              extractMetadata: widget.metadataExtractor ??
                  ImageService().extractMetadataFromBytesInBackground));
    } catch (_) {
      if (mounted && (route?.isCurrent ?? true)) {
        showErrorBar(context, tr('image_import_action_failed'));
      }
    } finally {
      if (mounted) {
        setState(() {
          _reading = false;
          _dialogOpen = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        widget.child,
        if (_reading)
          const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                  key: Key('generation-paste-loading'))),
      ]);
}
