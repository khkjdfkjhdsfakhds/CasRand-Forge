import 'dart:math';

sealed class NestedPrompt {
  String toPrompt();
  String toComment();

  NestedPrompt replaceVariables(
    Pattern pattern,
    List<PromptConfig> configList,
  );

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

  @override
  NestedPrompt replaceVariables(
    Pattern pattern,
    List<PromptConfig> configList,
  ) {
    // 执行实际替换逻辑
    final replaced = content.replaceAllMapped(
        pattern, (m) => _getReplacement(m[1]!, configList));
    return NestedPromptString(title: title, content: replaced);
  }

  String _getReplacement(String key, List<PromptConfig> configList) {
    try {
      return configList
          .firstWhere((e) => e.comment == key)
          .getPrmpts()
          .toPrompt();
    } catch (_) {
      return '__${key}__'; // 保持未替换状态
    }
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

  @override
  NestedPrompt replaceVariables(
    Pattern pattern,
    List<PromptConfig> configList,
  ) {
    // 递归处理子节点
    return NestedPromptList(
        title: title,
        children: children
            .map((c) => c.replaceVariables(pattern, configList))
            .toList());
  }
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

  int _sequentialIdx = 0;
  int _sequentialRepeatIdx = 0;

  PromptConfig({
    this.selectionMethod = 'all',
    this.shuffled = true,
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

  int calculateCombinations() {
    if (!enabled) return 1;
    if (type == 'str') {
      final n = usableEntryCount;
      if (n <= 1) return max(1, n);
      switch (selectionMethod) {
        case 'single':
          return n;
        case 'single_sequential':
          return n;
        case 'all':
          return 1;
        case 'multiple_num':
          final k = min(num, n);
          return _combinations(n, k);
        case 'multiple_prob':
          if (n >= 30) return 1000000000;
          return 1 << n;
        default:
          return n;
      }
    } else if (type == 'config') {
      final activeChildren = prompts.where((p) => p.enabled).toList();
      if (activeChildren.isEmpty) return 1;
      switch (selectionMethod) {
        case 'single':
          var total = 0;
          for (final child in activeChildren) {
            total += child.calculateCombinations();
          }
          return max(1, total);
        case 'single_sequential':
          var total = 0;
          for (final child in activeChildren) {
            total += child.calculateCombinations();
          }
          return max(1, total);
        case 'multiple_num':
          final k = min(num, activeChildren.length);
          if (k <= 0) return 1;
          final dp = List<int>.filled(k + 1, 0);
          dp[0] = 1;
          for (final child in activeChildren) {
            final c = child.calculateCombinations();
            for (var j = k; j >= 1; j--) {
              dp[j] += dp[j - 1] * c;
            }
          }
          return max(1, dp[k]);
        case 'multiple_prob':
          var product = 1;
          for (final child in activeChildren) {
            product *= (1 + child.calculateCombinations());
          }
          return product;
        case 'all':
        default:
          var product = 1;
          for (final child in activeChildren) {
            final childComb = child.calculateCombinations();
            if (childComb > 0) {
              product *= childComb;
            }
          }
          return max(1, product);
      }
    }
    return 1;
  }

  static int _combinations(int n, int k) {
    if (k <= 0 || k >= n) return 1;
    final effectiveK = min(k, n - k);
    var result = 1;
    for (var i = 1; i <= effectiveK; i++) {
      result = (result * (n - i + 1)) ~/ i;
    }
    return max(1, result);
  }

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

  NestedPrompt getPrmpts({bool filterEntryComments = true}) {
    List<dynamic> chosenPrompts = [];
    List<dynamic> promptsToChoose = [];
    if (type == 'str') {
      promptsToChoose = List.from(filterEntryComments ? usableEntries : strs);
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
        if (_sequentialIdx >= promptsToChoose.length) {
          _sequentialIdx = 0;
          _sequentialRepeatIdx = 0;
        }
        chosenPrompts = [promptsToChoose[_sequentialIdx]];
        _sequentialRepeatIdx++;
        if (_sequentialRepeatIdx >= max(1, num)) {
          _sequentialIdx = (_sequentialIdx + 1) % promptsToChoose.length;
          _sequentialRepeatIdx = 0;
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
        content: chosenPrompts.map((p) => addRandomBrackets(p)).join(', '),
      );
    } else if (type == 'config') {
      return NestedPromptList(
          title: comment,
          children: chosenPrompts
              .map((p) => (p as PromptConfig)
                  .getPrmpts(filterEntryComments: filterEntryComments))
              .toList());
    } else {
      throw UnimplementedError();
    }
  }

  void resetSequentialState() {
    _sequentialIdx = 0;
    _sequentialRepeatIdx = 0;
    for (final prompt in prompts) {
      prompt.resetSequentialState();
    }
  }
}
