import 'dart:typed_data';

import 'package:flutter_command/flutter_command.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

/// A read-only snapshot of one result card on the generation page.
class AgentResultView {
  /// Stable identity of the card; snapshots of the same card share it.
  final Object identity;

  /// running, waiting_retry, outcome_unknown, succeeded or failed.
  final String status;
  final String title;
  final String info;
  final Map<String, dynamic> details;
  final Uint8List? imageBytes;
  final String? currentFilePath;
  final List<String> savedFilePaths;
  final String? storageStatus;
  final String? storageError;
  final int? anlasCost;
  final int? anlasRemaining;
  final String? message;

  const AgentResultView({
    required this.identity,
    required this.status,
    required this.title,
    required this.info,
    this.details = const {},
    this.imageBytes,
    this.currentFilePath,
    this.savedFilePaths = const [],
    this.storageStatus,
    this.storageError,
    this.anlasCost,
    this.anlasRemaining,
    this.message,
  });
}

/// The generation controls an agent may use. The app binds it to the same
/// viewmodel the Generate button uses, so both paths share one state.
abstract class AgentGenerationPort {
  bool get isActive;
  bool get isStopping;

  /// A single run or a tool preparation is occupying the generator.
  bool get isBusy;
  int get completedCount;
  List<AgentResultView> get results;
  void start();
  void stop();
}

class ViewmodelGenerationPort implements AgentGenerationPort {
  ViewmodelGenerationPort(this._viewmodel, this._status);

  final GenerationPageViewmodel _viewmodel;
  final CommandStatus _status;

  @override
  bool get isActive => _status.isGenerationActive.value;

  @override
  bool get isStopping => _status.isStopping.value;

  @override
  bool get isBusy => _viewmodel.isBusyPreparingOrSingle;

  @override
  int get completedCount => _status.currentGenerationCount;

  @override
  List<AgentResultView> get results =>
      _status.commandList.map(_view).toList(growable: false);

  @override
  void start() => _viewmodel.startGeneration();

  @override
  void stop() => _viewmodel.stopGeneration();

  AgentResultView _view(Command<void, InfoCardContent> card) {
    final content = card.value;
    final waiting = _status.waitingFor(card);
    final unknown = _status.outcomeUnknownFor(card);
    final artifact = content.imageArtifact;
    final String status;
    if (waiting != null) {
      status = 'waiting_retry';
    } else if (unknown != null) {
      status = 'outcome_unknown';
    } else if (_status.isExecuting(card)) {
      status = 'running';
    } else if (content.hasImage) {
      status = 'succeeded';
    } else {
      status = 'failed';
    }
    return AgentResultView(
      identity: card,
      status: status,
      title: content.title,
      info: content.info,
      details: content.additionalInfo,
      imageBytes: content.imageBytes,
      currentFilePath: content.currentImageFile?.path,
      savedFilePaths: artifact == null
          ? const []
          : artifact.permanentFiles.map((file) => file.path).toList(),
      storageStatus: artifact?.status.name,
      storageError: artifact?.failure?.toString(),
      anlasCost: content.anlasCost,
      anlasRemaining: content.anlasRemaining,
      message: waiting?.message ?? unknown?.message,
    );
  }
}
