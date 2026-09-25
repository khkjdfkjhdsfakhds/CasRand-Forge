import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/prompt_token_snapshot.dart';
import 'package:nai_casrand/data/services/prompt_token_service.dart';
import 'package:nai_casrand/data/use_cases/prompt_tokenizer.dart';

typedef PromptTokenCounter = Future<List<int>> Function(String, List<String>);

class PromptTokenUsage extends StatefulWidget {
  final Map<String, dynamic> metadata;
  final PromptTokenCounter? counter;
  final Widget Function(Widget positiveBar, Widget negativeBar)? builder;
  const PromptTokenUsage(
      {super.key, required this.metadata, this.counter, this.builder});
  @override
  State<PromptTokenUsage> createState() => _PromptTokenUsageState();
}

class _PromptTokenUsageState extends State<PromptTokenUsage> {
  Timer? _debounce;
  int _epoch = 0;
  PromptTokenSnapshot? _snapshot;
  List<int>? _counts;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _afterFrame();
  }

  @override
  void didUpdateWidget(PromptTokenUsage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.metadata, widget.metadata)) _refresh();
  }

  void _afterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _refresh() {
    final snapshot = PromptTokenSnapshot.fromMetadata(widget.metadata);
    final epoch = ++_epoch;
    _debounce?.cancel();
    setState(() {
      _snapshot = snapshot;
      _counts = null;
      _failed = false;
    });
    if (snapshot == null) return;
    _debounce = Timer(const Duration(milliseconds: 180), () async {
      try {
        final counts = await (widget.counter ??
            PromptTokenService.instance.count)(snapshot.model, snapshot.texts);
        if (!mounted || epoch != _epoch) return;
        setState(() {
          _counts = counts;
        });
      } catch (_) {
        if (!mounted || epoch != _epoch) return;
        setState(() {
          _failed = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return widget.builder
              ?.call(const SizedBox.shrink(), const SizedBox.shrink()) ??
          const SizedBox.shrink();
    }
    final positive = _bar(context, snapshot, negative: false);
    final negative = _bar(context, snapshot, negative: true);
    return widget.builder?.call(positive, negative) ??
        Column(mainAxisSize: MainAxisSize.min, children: [positive, negative]);
  }

  Widget _bar(BuildContext context, PromptTokenSnapshot snapshot,
      {required bool negative}) {
    final title =
        tr(negative ? 'prompt_tokens_negative' : 'prompt_tokens_positive');
    final length = snapshot.positive.length;
    final counts = _counts;
    final values = counts == null
        ? null
        : negative
            ? counts.skip(length).toList()
            : counts.take(length).toList();
    final used = values?.fold<int>(0, (a, b) => a + b);
    final limit = promptTokenLimit(snapshot.model);
    final legacy =
        promptTokenizerFor(snapshot.model) == PromptTokenizerKind.clip;
    final summary =
        '$title${legacy ? ' (${tr('prompt_tokens_largest_chunk')})' : ''} ${used ?? '—'}/$limit';
    final message = [
      summary,
      if (_failed) tr('prompt_tokens_failed'),
      if (_failed) tr('prompt_tokens_retry'),
      if (!_failed && values == null) tr('prompt_tokens_loading'),
      if (values != null && values.length > 1)
        for (var i = 0; i < values.length; i++)
          '${i == 0 ? tr('prompt_tokens_base') : tr('prompt_tokens_character', namedArgs: {
                  'number': '$i'
                })}: ${values[i]}',
    ].join('\n');
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.tap,
      waitDuration: const Duration(milliseconds: 300),
      showDuration: const Duration(seconds: 5),
      preferBelow: false,
      child: Semantics(
        label: tr('prompt_tokens'),
        value: message,
        button: _failed,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: ValueKey(
                negative ? 'prompt-token-negative' : 'prompt-token-positive'),
            behavior: HitTestBehavior.opaque,
            onTap: _failed ? _refresh : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: LinearProgressIndicator(
                key: ValueKey(negative
                    ? 'prompt-token-negative-fill'
                    : 'prompt-token-positive-fill'),
                value: ((used ?? 0) / limit).clamp(0.0, 1.0),
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
                trackGap: 0,
                stopIndicatorRadius: 0,
                color: used != null && used > limit
                    ? colors.error
                    : colors.primary,
                backgroundColor: colors.onSurface.withValues(alpha: 0.08),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
