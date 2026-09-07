import 'package:flutter/foundation.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';

class GenerationCardProgress {
  const GenerationCardProgress({
    required this.taskNumber,
    required this.totalTaskCount,
  });

  final int taskNumber;
  final int? totalTaskCount;
}

class GenerationCardWaiting {
  const GenerationCardWaiting({required this.retryAt, required this.message});
  final DateTime retryAt;
  final String message;
}

class GenerationCardOutcomeUnknown {
  const GenerationCardOutcomeUnknown({this.message});
  final String? message;
}

class CommandStatus extends ChangeNotifier {
  List<Command<void, InfoCardContent>> commandList = [];
  DateTime generationTimestamp = DateTime.now();

  int currentGenerationCount = 0;

  final Map<Command<void, InfoCardContent>, GenerationCardProgress>
      _generationCardProgress = {};

  final Map<Command<void, InfoCardContent>, Command<void, InfoCardContent>>
      _attempts = {};
  final Map<Command<void, InfoCardContent>, GenerationCardWaiting> _waiting =
      {};
  final Map<Command<void, InfoCardContent>, GenerationCardOutcomeUnknown>
      _unknown = {};

  /// The historical command is the stable card identity. A retry command only
  /// supplies live execution state; replacing the card loses scroll identity.
  void bindAttempt(Command<void, InfoCardContent> card,
      Command<void, InfoCardContent> attempt) {
    unbindAttempt(card);
    _attempts[card] = attempt;
    attempt.isExecuting.addListener(notifyListeners);
    attempt.addListener(notifyListeners);
    clearState(card);
  }

  void unbindAttempt(Command<void, InfoCardContent> card) {
    final old = _attempts.remove(card);
    if (old == null) return;
    old.isExecuting.removeListener(notifyListeners);
    old.removeListener(notifyListeners);
    notifyListeners();
  }

  bool isExecuting(Command<void, InfoCardContent> card) =>
      !_waiting.containsKey(card) &&
      !_unknown.containsKey(card) &&
      (_attempts[card] ?? card).isExecuting.value;

  String? tokenLabelFor(Command<void, InfoCardContent> card) =>
      _attempts[card]?.value.tokenLabel ?? card.value.tokenLabel;

  GenerationCardWaiting? waitingFor(Command<void, InfoCardContent> card) =>
      _waiting[card];
  GenerationCardOutcomeUnknown? outcomeUnknownFor(
          Command<void, InfoCardContent> card) =>
      _unknown[card];

  void setWaiting(
    Command<void, InfoCardContent> card, {
    required DateTime retryAt,
    required String message,
  }) {
    _unknown.remove(card);
    _waiting[card] = GenerationCardWaiting(retryAt: retryAt, message: message);
    notifyListeners();
  }

  void setOutcomeUnknown(Command<void, InfoCardContent> card,
      {String? message}) {
    _waiting.remove(card);
    _unknown[card] = GenerationCardOutcomeUnknown(message: message);
    notifyListeners();
  }

  void clearState(Command<void, InfoCardContent> card) {
    _waiting.remove(card);
    _unknown.remove(card);
    notifyListeners();
  }

  GenerationCardProgress? progressFor(
    Command<void, InfoCardContent> command,
  ) =>
      _generationCardProgress[command];

  String requestingLabel(
    Command<void, InfoCardContent> command, {
    required int configuredTotal,
  }) {
    final progress = progressFor(command);
    final current = progress?.taskNumber ?? currentGenerationCount;
    final total = progress?.totalTaskCount ??
        (configuredTotal != 0 && progress == null ? configuredTotal : null);
    return 'Requesting $current/${total ?? '∞'} ...';
  }

  void setProgress(
    Command<void, InfoCardContent> command, {
    required int taskNumber,
    required int? totalTaskCount,
  }) {
    _generationCardProgress[command] = GenerationCardProgress(
      taskNumber: taskNumber,
      totalTaskCount: totalTaskCount,
    );
  }

  void removeProgress(Command<void, InfoCardContent> command) {
    _generationCardProgress.remove(command);
    unbindAttempt(command);
    clearState(command);
  }

  @override
  void dispose() {
    for (final attempt in _attempts.values) {
      attempt.isExecuting.removeListener(notifyListeners);
      attempt.removeListener(notifyListeners);
    }
    _attempts.clear();
    _waiting.clear();
    _unknown.clear();
    _generationCardProgress.clear();
    super.dispose();
  }

  ValueNotifier<bool> isGenerationActive = ValueNotifier(false);
  ValueNotifier<bool> isStopping = ValueNotifier(false);
  ValueNotifier<bool> isWaitingForNextGeneration = ValueNotifier(false);
}
