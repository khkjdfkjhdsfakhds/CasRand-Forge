import 'package:flutter/foundation.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';

class CommandStatus {
  List<Command<void, InfoCardContent>> commandList = [];
  DateTime generationTimestamp = DateTime.now();

  int currentGenerationCount = 0;

  ValueNotifier<bool> isGenerationActive = ValueNotifier(false);
  ValueNotifier<bool> isWaitingForNextGeneration = ValueNotifier(false);
}
