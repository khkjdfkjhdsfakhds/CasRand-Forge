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

class CommandStatus {
  List<Command<void, InfoCardContent>> commandList = [];
  DateTime generationTimestamp = DateTime.now();

  int currentGenerationCount = 0;

  final Map<Command<void, InfoCardContent>, GenerationCardProgress>
      _generationCardProgress = {};

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
  }

  ValueNotifier<bool> isGenerationActive = ValueNotifier(false);
  ValueNotifier<bool> isStopping = ValueNotifier(false);
  ValueNotifier<bool> isWaitingForNextGeneration = ValueNotifier(false);
}
