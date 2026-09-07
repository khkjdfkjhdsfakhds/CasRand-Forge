import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/batch_tool_snapshot.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_token_snapshot.dart';
import 'package:nai_casrand/data/services/prompt_token_service.dart';
import 'package:nai_casrand/data/use_cases/prompt_tokenizer.dart';

typedef PromptTokenCounter = Future<List<int>> Function(String, List<String>);

class PromptTokenUsage extends StatefulWidget {
  final PayloadConfig config;
  final PromptTokenCounter? counter;
  final PromptTokenSnapshots? snapshots;
  const PromptTokenUsage(
      {super.key, required this.config, this.counter, this.snapshots});
  @override
  State<PromptTokenUsage> createState() => _PromptTokenUsageState();
}

class _PromptTokenUsageState extends State<PromptTokenUsage> {
  Timer? _debounce;
  int _epoch = 0;
  PromptTokenSnapshot? _snapshot;
  List<int>? _counts;
  bool _failed = false;
  TabController? _tabs;
  PromptTokenSnapshots get store =>
      widget.snapshots ?? PromptTokenSnapshots.instance;
  @override
  void initState() {
    super.initState();
    store.addListener(_afterFrame);
    widget.config.i2iConfig.addListener(_afterFrame);
    _afterFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tabs = DefaultTabController.maybeOf(context);
    if (!identical(tabs, _tabs)) {
      _tabs?.removeListener(_afterFrame);
      _tabs = tabs;
      _tabs?.addListener(_afterFrame);
    }
    _afterFrame();
  }

  @override
  void didUpdateWidget(PromptTokenUsage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config) {
      oldWidget.config.i2iConfig.removeListener(_afterFrame);
      widget.config.i2iConfig.addListener(_afterFrame);
    }
    if (oldWidget.snapshots != widget.snapshots) {
      (oldWidget.snapshots ?? PromptTokenSnapshots.instance)
          .removeListener(_afterFrame);
      store.addListener(_afterFrame);
    }
    _afterFrame();
  }

  void _afterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _refresh({bool retry = false}) {
    final snapshot =
        PromptTokenSnapshot.fixed(widget.config) ?? store.latest(widget.config);
    if (!retry &&
        snapshot?.model == _snapshot?.model &&
        snapshot?.recentTask == _snapshot?.recentTask &&
        listEquals(snapshot?.positive, _snapshot?.positive) &&
        listEquals(snapshot?.negative, _snapshot?.negative)) {
      return;
    }
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
    _tabs?.removeListener(_afterFrame);
    store.removeListener(_afterFrame);
    widget.config.i2iConfig.removeListener(_afterFrame);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.config.activeBatchTool?.kind == BatchToolKind.director) {
      return const SizedBox.shrink();
    }
    final snapshot = _snapshot;
    final counts = _counts;
    final limit =
        promptTokenLimit(snapshot?.model ?? widget.config.paramConfig.model);
    final positive =
        counts?.take(snapshot!.positive.length).fold(0, (a, b) => a + b);
    final negative =
        counts?.skip(snapshot!.positive.length).fold(0, (a, b) => a + b);
    final status = snapshot == null
        ? tr('prompt_tokens_after_generation')
        : _failed
            ? tr('prompt_tokens_failed')
            : counts == null
                ? tr('prompt_tokens_loading')
                : null;
    final legacyChunks = promptTokenizerFor(
            snapshot?.model ?? widget.config.paramConfig.model) ==
        PromptTokenizerKind.clip;
    Widget total(String title, int? used) => Text(
        '$title${legacyChunks ? ' (${tr('prompt_tokens_largest_chunk')})' : ''} ${used ?? '—'}/$limit',
        style: TextStyle(
            color: used != null && used > limit
                ? Theme.of(context).colorScheme.error
                : null));
    return ExpansionTile(
      key: const Key('prompt-token-usage'),
      leading: const Icon(Icons.data_usage),
      title: Text(tr('prompt_tokens')),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 16, children: [
          total(tr('prompt_tokens_positive'), positive),
          total(tr('prompt_tokens_negative'), negative)
        ]),
        Text(status ??
            tr(snapshot!.recentTask
                ? 'prompt_tokens_recent'
                : 'prompt_tokens_current')),
      ]),
      children: [
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(tr('prompt_tokens_explanation'))),
        if (snapshot != null)
          ListTile(
              dense: true,
              title: Text(snapshot.model),
              subtitle: Text(tr(snapshot.recentTask
                  ? 'prompt_tokens_recent'
                  : 'prompt_tokens_current'))),
        if (_failed)
          TextButton(
              onPressed: () => _refresh(retry: true),
              child: Text(tr('prompt_tokens_retry'))),
        if (counts != null && snapshot != null)
          for (var i = 0; i < snapshot.positive.length; i++)
            ListTile(
                dense: true,
                title: Text(i == 0
                    ? tr('prompt_tokens_base')
                    : tr('prompt_tokens_character',
                        namedArgs: {'number': '$i'})),
                trailing: Text(
                    '${tr('prompt_tokens_positive')} ${counts[i]} · ${tr('prompt_tokens_negative')} ${counts[snapshot.positive.length + i]}')),
      ],
    );
  }
}
