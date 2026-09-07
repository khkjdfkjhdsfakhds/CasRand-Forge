import 'dart:math';

sealed class NestedPrompt {
  String toPrompt();
  String toComment();

  /// DFS search that returns prompt with specified key.
  String? findPromptWithKey(String key);
}

/// Leaf node with no child.
class NestedPromptString extends NestedPrompt {
  String title;
  String content;
  NestedPromptString({
    required this.title,
    required this.content,
  });

  @override
  String toPrompt() {
    return content;
  }

  @override
  String toComment() {
    return '$title: $content';
  }

  @override
  String? findPromptWithKey(String key) {
    if (title == key) return content;
    return null;
  }
}

/// Root node with a list of children.
class NestedPromptList extends NestedPrompt {
  String title;
  List<NestedPrompt> children;

  NestedPromptList({required this.title, required this.children});

  @override
  String toPrompt() {
    return children
        .map((child) => child.toPrompt())
        .where((prompt) => prompt.isNotEmpty)
        .join(', ');
  }

  @override
  String toComment() {
    if (children.isEmpty) return '$title: <None>';
    var result = '$title:\n';
    for (final (idx, child) in children.indexed) {
      final comment = child.toComment();
      result += _indent(comment.isNotEmpty ? comment : '<None>', 2);
      if (idx != children.length - 1) result += '\n';
    }
    return result;
  }

  @override
  String? findPromptWithKey(String key) {
    if (key == title) return toPrompt();
    for (final child in children) {
      final result = child.findPromptWithKey(key);
      if (result != null) return result;
    }
    return null;
  }

  /// Aux function that splits string and adds indent to each line.
  String _indent(String str, int spaces) {
    var indentation = ' ' * spaces;
    var lines = str.split('\n');
    return lines.map((line) => '$indentation$line').join('\n');
  }
}

class _SequentialProgress {
  int index = 0;
  int repeatIndex = 0;
}

class _ReferenceOccurrence {
  _ReferenceOccurrence(this.template);
  final PromptConfig template;
  final progress = Expando<_SequentialProgress>();
}

class _EntryReferences {
  _EntryReferences(this.source);
  final String source;
  final occurrences = <int, _ReferenceOccurrence>{};
}

class _TextEntry {
  const _TextEntry(this.index, this.text);
  final int index;
  final String text;
}

class PromptConfig {
  String selectionMethod;
  bool shuffled;
  double prob;
  int num;
  int randomBracketsUpper;
  int randomBracketsLower;
  String type;
  String comment;
  String filter;
  List<String> strs;
  List<PromptConfig> prompts;
  bool enabled;
  bool useAsFileNamePrefix;

  _SequentialProgress _sequential = _SequentialProgress();
  final _entryReferences = <int, _EntryReferences>{};

  static final _referencePattern = RegExp(
    r'__([\p{L}0-9_\-（）().\u4e00-\u9fff\uff00-\uffef]+?)__',
    unicode: true,
  );

  static PromptConfig? _findReference(String key, List<PromptConfig> saved) {
    for (final template in saved) {
      if (template.comment == key) return template;
    }
    return null;
  }

  String _resolveReferences(_TextEntry entry, List<PromptConfig> saved) {
    // Identity is the owning node + original entry slot + occurrence ordinal,
    // before random brackets or output shuffling. Editing a source entry
    // resets only that entry; moving an unchanged node retains its progress.
    final state = _entryReferences.putIfAbsent(
      entry.index,
      () => _EntryReferences(strs[entry.index]),
    );
    var ordinal = 0;
    return entry.text.replaceAllMapped(_referencePattern, (match) {
      final position = ordinal++;
      final template = _findReference(match[1]!, saved);
      if (template == null) {
        state.occurrences.remove(position);
        return match[0]!;
      }
      var occurrence = state.occurrences[position];
      if (occurrence == null || !identical(occurrence.template, template)) {
        occurrence = _ReferenceOccurrence(template);
        state.occurrences[position] = occurrence;
      }
      // Deliberately one pass: text inserted by a template is not expanded.
      try {
        return template._getPrmpts(progress: occurrence.progress).toPrompt();
      } catch (_) {
        // Preserve the legacy unresolved-placeholder behavior for malformed
        // saved templates; reference independence is not a new error policy.
        return match[0]!;
      }
    });
  }

  PromptConfig({
    this.selectionMethod = 'all',
    this.shuffled = false,
    this.prob = 0.0,
    this.num = 1,
    this.randomBracketsUpper = 0,
    this.randomBracketsLower = 0,
    this.type = 'str',
    this.comment = 'Unnamed config',
    this.filter = '',
    required this.strs,
    required this.prompts,
    this.enabled = true,
    this.useAsFileNamePrefix = false,
  });

  factory PromptConfig.fromJson(Map<String, dynamic> json) {
    int upper, lower;
    if (json['randomBrackets'] != null) {
      upper = json['randomBrackets'];
      lower = -json['randomBrackets'];
    } else {
      upper = json['randomBracketsUpper'];
      lower = json['randomBracketsLower'];
    }

    return PromptConfig(
      selectionMethod: json['selectionMethod'],
      shuffled: json['shuffled'],
      prob:
          json['prob'] is int ? (json['prob'] as int).toDouble() : json['prob'],
      num: max(1, json['num'] ?? 1),
      randomBracketsUpper: upper.toInt(),
      randomBracketsLower: lower.toInt(),
      type: json['type'],
      comment: json['comment'],
      filter: json['filter'],
      strs:
          (json['strs'] as List<dynamic>?)?.map((e) => e as String).toList() ??
              [],
      prompts: (json['prompts'] as List<dynamic>?)
              ?.map((e) => PromptConfig.fromJson(e))
              .toList() ??
          [],
      enabled: json['enabled'] ?? true,
      useAsFileNamePrefix: json['useAsFileNamePrefix'] ??
          json['use_as_file_name_prefix'] ??
          false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'selectionMethod': selectionMethod,
      'shuffled': shuffled,
      'prob': prob,
      'num': num,
      'randomBracketsUpper': randomBracketsUpper,
      'randomBracketsLower': randomBracketsLower,
      'type': type,
      'comment': comment,
      'filter': filter,
      'strs': strs,
      'prompts': prompts.map((x) => x.toJson()).toList(),
      'enabled': enabled,
      'useAsFileNamePrefix': useAsFileNamePrefix,
    };
  }

  List<String> collectPrefixComments() {
    final result = <String>[];
    if (!enabled) return result;
    if (useAsFileNamePrefix && comment.trim().isNotEmpty) {
      result.add(comment.trim());
    }
    if (type == 'config') {
      for (final child in prompts) {
        result.addAll(child.collectPrefixComments());
      }
    }
    return result;
  }

  /// A full deterministic state cycle, not a count of distinct strings.
  /// Reading this never evaluates prompts or touches selection progress.
  int calculateCombinations() =>
      taskCountForCycle(calculateCombinationCycle()) ??
      (throw RangeError('Prompt cycle exceeds the task counter range'));

  /// The scheduler also needs to represent the next task number. Check the
  /// round trip and increment so native overflow and JS rounding both fail
  /// explicitly rather than creating a truncated or unlimited (zero) batch.
  static int? taskCountForCycle(BigInt cycle) {
    final count = int.tryParse(cycle.toString());
    if (count == null ||
        count <= 0 ||
        BigInt.from(count) != cycle ||
        BigInt.from(count + 1) != cycle + BigInt.one) {
      return null;
    }
    return count;
  }

  BigInt calculateCombinationCycle({
    bool filterEntryComments = true,
    List<PromptConfig>? savedConfigs,
  }) {
    if (!enabled || (type != 'config' && type != 'str')) return BigInt.one;
    final cycles = type == 'config'
        ? prompts.where((p) => p.enabled).map((p) =>
            p.calculateCombinationCycle(
                filterEntryComments: filterEntryComments,
                savedConfigs: savedConfigs))
        : (filterEntryComments ? usableEntries : strs)
            .map((text) => combineCycles(
                  savedConfigs == null
                      ? <BigInt>[]
                      : _referencePattern.allMatches(text).map((match) =>
                          _findReference(match[1]!, savedConfigs)
                              ?.calculateCombinationCycle() ??
                          BigInt.one),
                ));
    // Mapped iterable length does not evaluate child periods. Random branches
    // can stop here without walking their otherwise unused nested cycles.
    final count = cycles.length;
    if (count == 0) return BigInt.one;
    switch (selectionMethod) {
      case 'single':
        return count == 1 ? cycles.single : BigInt.one;
      case 'multiple_num':
        return num >= count ? combineCycles(cycles) : BigInt.one;
      case 'multiple_prob':
        return prob >= 1 ? combineCycles(cycles) : BigInt.one;
      case 'single_sequential':
        final repeat = BigInt.from(max(1, num));
        // Each child is called r times per parent rotation. Its paused state
        // returns after P/gcd(P,r) rotations, not after P output strings.
        return BigInt.from(count) *
            repeat *
            combineCycles(
              cycles.map((period) => period ~/ period.gcd(repeat)),
            );
    }
    return combineCycles(cycles);
  }

  static BigInt combineCycles(Iterable<BigInt> cycles) => cycles.fold(
        BigInt.one,
        (a, b) => (a ~/ a.gcd(b)) * b,
      );

  static bool isCommentLine(String line) => line.trimLeft().startsWith('#');

  static String? promptTextForEntry(String entry) {
    final promptLines = entry
        .split(RegExp(r'\r?\n'))
        .where((line) => !isCommentLine(line))
        .toList(growable: false);
    if (!promptLines.any((line) => line.trim().isNotEmpty)) return null;
    return promptLines.join('\n');
  }

  static bool entryHasPrompt(String entry) => promptTextForEntry(entry) != null;

  List<String> get usableEntries =>
      strs.map(promptTextForEntry).whereType<String>().toList(growable: false);

  int get usableEntryCount => usableEntries.length;

  int? get firstUsableEntryIndex {
    final index = strs.indexWhere(entryHasPrompt);
    return index < 0 ? null : index;
  }

  String addRandomBrackets(String s) {
    int n = randomBracketsLower +
        Random().nextInt(randomBracketsUpper - randomBracketsLower + 1);
    List<String> brackets;

    if (n < 0) {
      brackets = ["[", "]"];
      n = -n;
    } else {
      brackets = ["{", "}"];
    }

    final bracketString = List.from(brackets.map((b) => b * n));
    return bracketString[0] + s + bracketString[1];
  }

  NestedPrompt getPrmpts({
    bool filterEntryComments = true,
    List<PromptConfig>? savedConfigs,
  }) =>
      _getPrmpts(
        filterEntryComments: filterEntryComments,
        savedConfigs: savedConfigs,
      );

  NestedPrompt _getPrmpts({
    bool filterEntryComments = true,
    List<PromptConfig>? savedConfigs,
    Expando<_SequentialProgress>? progress,
  }) {
    if (!enabled) return NestedPromptString(title: comment, content: '');
    final sequential = progress == null
        ? _sequential
        : (progress[this] ??= _SequentialProgress());
    List<dynamic> chosenPrompts = [];
    List<dynamic> promptsToChoose = [];
    if (type == 'str') {
      promptsToChoose = [
        for (final (index, entry) in strs.indexed)
          if ((filterEntryComments ? promptTextForEntry(entry) : entry)
              case final String text)
            _TextEntry(index, text),
      ];
      _entryReferences.removeWhere((index, state) =>
          index >= strs.length || state.source != strs[index]);
    } else if (type == 'config') {
      promptsToChoose = List.from(prompts.where((p) => p.enabled));
    }
    final random = Random();

    switch (selectionMethod) {
      case 'single':
        if (promptsToChoose.isNotEmpty) {
          chosenPrompts
              .add(promptsToChoose[random.nextInt(promptsToChoose.length)]);
        }
        break;
      case 'all':
        chosenPrompts = promptsToChoose;
        break;
      case 'multiple_prob':
        chosenPrompts =
            promptsToChoose.where((_) => random.nextDouble() < prob).toList();
        break;
      case 'multiple_num':
        chosenPrompts = List.from(promptsToChoose);
        chosenPrompts.shuffle();
        chosenPrompts = chosenPrompts.take(num).toList();
        break;
      case 'single_sequential':
        if (promptsToChoose.isEmpty) break;
        if (sequential.index >= promptsToChoose.length) {
          sequential.index = 0;
          sequential.repeatIndex = 0;
        }
        chosenPrompts = [promptsToChoose[sequential.index]];
        sequential.repeatIndex++;
        if (sequential.repeatIndex >= max(1, num)) {
          sequential.index = (sequential.index + 1) % promptsToChoose.length;
          sequential.repeatIndex = 0;
        }
        break;
      default:
        chosenPrompts = List.from(promptsToChoose);
    }

    if (shuffled) {
      chosenPrompts.shuffle();
    }

    if (type == 'str') {
      return NestedPromptString(
        title: comment,
        content: chosenPrompts.map((p) {
          final entry = p as _TextEntry;
          final text = savedConfigs == null
              ? entry.text
              : _resolveReferences(entry, savedConfigs);
          return addRandomBrackets(text);
        }).join(', '),
      );
    } else if (type == 'config') {
      return NestedPromptList(
          title: comment,
          children: chosenPrompts
              .map((p) => (p as PromptConfig)._getPrmpts(
                  filterEntryComments: filterEntryComments,
                  savedConfigs: savedConfigs,
                  progress: progress))
              .toList());
    } else {
      throw UnimplementedError();
    }
  }

  void resetSequentialState() {
    _sequential = _SequentialProgress();
    _entryReferences.clear();
    for (final prompt in prompts) {
      prompt.resetSequentialState();
    }
  }
}
