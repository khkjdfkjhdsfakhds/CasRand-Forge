import 'dart:collection';

/// One assignment of a logical generation task to an account worker.
class GenerationLease {
  const GenerationLease({
    required this.taskNumber,
    required this.attemptNumber,
    required this.workerId,
  });

  final int taskNumber;
  final int attemptNumber;
  final String workerId;
}

class GenerationSchedulerStatus {
  const GenerationSchedulerStatus({
    required this.inFlightCount,
    required this.completedTaskCount,
    required this.stopRequested,
    required this.finished,
    required this.allWorkersPaused,
    required this.abandonedTaskCount,
    this.suspendedTaskCount = 0,
  });

  final int inFlightCount;
  final int completedTaskCount;
  final bool stopRequested;
  final bool finished;
  final bool allWorkersPaused;
  final int abandonedTaskCount;
  final int suspendedTaskCount;
}

class GenerationFailureResult {
  const GenerationFailureResult({
    required this.consecutiveFailureCount,
    required this.workerPaused,
    required this.taskRequeued,
  });

  final int consecutiveFailureCount;
  final bool workerPaused;
  final bool taskRequeued;
}

/// Pure in-memory scheduler for a batch of unique logical generation tasks.
class GenerationScheduler {
  GenerationScheduler(
      {required this.taskCount, required Iterable<String> workerIds})
      : _workerIds = Set<String>.of(workerIds) {
    if (taskCount < 0) {
      throw ArgumentError.value(taskCount, 'taskCount', 'must not be negative');
    }
    if (_workerIds.isEmpty) {
      throw ArgumentError.value(workerIds, 'workerIds', 'must not be empty');
    }
  }

  /// Zero means an unlimited batch.
  final int taskCount;
  final Set<String> _workerIds;
  final Map<String, GenerationLease> _workerLeases = {};
  final Set<GenerationLease> _issuedLeases = {};
  final Map<String, GenerationLease> _lastWorkerClaims = {};
  final ListQueue<int> _retryQueue = ListQueue<int>();
  final Map<int, int> _taskAttemptNumbers = {};
  final Set<GenerationLease> _suspendedLeases = {};
  final Set<int> _cancelledTasks = {};
  final Set<int> _completedTasks = {};
  final Map<int, GenerationLease> _successReservations = {};
  final Map<String, int> _workerFailureCounts = {};
  final Set<String> _pausedWorkers = {};
  int _nextTaskNumber = 1;
  bool _stopRequested = false;

  GenerationLease? claim(String workerId) {
    if (_stopRequested ||
        !_workerIds.contains(workerId) ||
        _workerLeases.containsKey(workerId) ||
        _pausedWorkers.contains(workerId)) {
      return null;
    }
    final int taskNumber;
    if (_retryQueue.isNotEmpty) {
      taskNumber = _retryQueue.removeFirst();
    } else {
      if (taskCount != 0 && _nextTaskNumber > taskCount) return null;
      taskNumber = _nextTaskNumber++;
    }
    final attemptNumber = (_taskAttemptNumbers[taskNumber] ?? 0) + 1;
    _taskAttemptNumbers[taskNumber] = attemptNumber;
    final lease = GenerationLease(
      taskNumber: taskNumber,
      attemptNumber: attemptNumber,
      workerId: workerId,
    );
    _workerLeases[workerId] = lease;
    _lastWorkerClaims[workerId] = lease;
    _issuedLeases.add(lease);
    return lease;
  }

  /// Quarantines a request with an unknown outcome, without replaying it.
  bool suspendOutcome(GenerationLease lease, {bool pauseWorker = true}) {
    if (!_issuedLeases.contains(lease) ||
        _successReservations.containsKey(lease.taskNumber) ||
        _completedTasks.contains(lease.taskNumber)) {
      return false;
    }
    if (_suspendedLeases.contains(lease)) return true;
    if (!identical(_workerLeases[lease.workerId], lease)) return false;
    _suspendedLeases.add(lease);
    if (identical(_workerLeases[lease.workerId], lease)) {
      _workerLeases.remove(lease.workerId);
    }
    if (pauseWorker) _pausedWorkers.add(lease.workerId);
    _retryQueue.removeWhere((number) => number == lease.taskNumber);
    return true;
  }

  /// Reserves the first valid NovelAI response for a logical task.
  bool reserveSuccess(GenerationLease lease) {
    if (!_issuedLeases.contains(lease)) return false;
    final reserved = _successReservations[lease.taskNumber];
    if (_completedTasks.contains(lease.taskNumber) ||
        _cancelledTasks.contains(lease.taskNumber) ||
        (reserved != null && !identical(reserved, lease))) {
      _discardLease(lease);
      return false;
    }
    _successReservations[lease.taskNumber] = lease;
    _retryQueue.removeWhere((taskNumber) => taskNumber == lease.taskNumber);
    return true;
  }

  /// Releases only the API-worker slot while the winning response crosses the
  /// paid-result boundary. Storage is deliberately not scheduler state.
  bool detachWorkerForPersistence(GenerationLease lease) {
    if (!identical(_successReservations[lease.taskNumber], lease) ||
        !_issuedLeases.contains(lease)) {
      return false;
    }
    if (identical(_workerLeases[lease.workerId], lease)) {
      _workerLeases.remove(lease.workerId);
    }
    return true;
  }

  /// Completes a task once its reserved generation response is valid.
  bool completeSuccess(GenerationLease lease) {
    if (!identical(_successReservations[lease.taskNumber], lease)) {
      return false;
    }
    _successReservations.remove(lease.taskNumber);
    if (!_issuedLeases.remove(lease)) return false;
    _suspendedLeases.remove(lease);
    if (identical(_workerLeases[lease.workerId], lease)) {
      _workerLeases.remove(lease.workerId);
    }
    if (!_taskAttemptNumbers.containsKey(lease.taskNumber) ||
        !_completedTasks.add(lease.taskNumber)) {
      return false;
    }
    // Persistence and unknown-outcome responses can complete out of order.
    // An older success says nothing about a worker's more recent failure.
    if (identical(_lastWorkerClaims[lease.workerId], lease)) {
      _workerFailureCounts[lease.workerId] = 0;
      _pausedWorkers.remove(lease.workerId);
    }
    _retryQueue.removeWhere((taskNumber) => taskNumber == lease.taskNumber);
    _issuedLeases.removeWhere(
      (issued) =>
          issued.taskNumber == lease.taskNumber &&
          !identical(_workerLeases[issued.workerId], issued),
    );
    return true;
  }

  GenerationFailureResult completeFailure(GenerationLease lease,
      {bool pauseWorker = false}) {
    final isCurrentWorkerLease =
        identical(_workerLeases[lease.workerId], lease);
    final isReservedSuccess =
        identical(_successReservations[lease.taskNumber], lease);
    if (isReservedSuccess) {
      throw StateError(
        'A reserved successful response cannot be requeued as a generation '
        'failure.',
      );
    }
    if (!isCurrentWorkerLease && !isReservedSuccess) {
      return GenerationFailureResult(
        consecutiveFailureCount: _workerFailureCounts[lease.workerId] ?? 0,
        workerPaused: _pausedWorkers.contains(lease.workerId),
        taskRequeued: false,
      );
    }
    if (isCurrentWorkerLease) _workerLeases.remove(lease.workerId);
    final failureCount = (_workerFailureCounts[lease.workerId] ?? 0) + 1;
    _workerFailureCounts[lease.workerId] = failureCount;
    if (pauseWorker || failureCount >= 5) {
      _pausedWorkers.add(lease.workerId);
    }
    final taskRequeued = !_completedTasks.contains(lease.taskNumber) &&
        !_successReservations.containsKey(lease.taskNumber);
    if (taskRequeued) {
      _retryQueue.removeWhere((taskNumber) => taskNumber == lease.taskNumber);
      _retryQueue.addFirst(lease.taskNumber);
    }
    return GenerationFailureResult(
      consecutiveFailureCount: failureCount,
      workerPaused: _pausedWorkers.contains(lease.workerId),
      taskRequeued: taskRequeued,
    );
  }

  /// Cancels a definitely unsent attempt without charging an account failure.
  bool cancel(GenerationLease lease) {
    if (!_issuedLeases.contains(lease) ||
        _successReservations.containsKey(lease.taskNumber) ||
        _completedTasks.contains(lease.taskNumber) ||
        !identical(_workerLeases[lease.workerId], lease) ||
        _suspendedLeases.contains(lease)) {
      return false;
    }
    _discardLease(lease);
    _cancelledTasks.add(lease.taskNumber);
    _retryQueue.removeWhere((number) => number == lease.taskNumber);
    return true;
  }

  void requestStop() {
    _stopRequested = true;
  }

  void _discardLease(GenerationLease lease) {
    _issuedLeases.remove(lease);
    _suspendedLeases.remove(lease);
    if (identical(_workerLeases[lease.workerId], lease)) {
      _workerLeases.remove(lease.workerId);
    }
  }

  GenerationSchedulerStatus get status {
    final allWorkersPaused = _pausedWorkers.length == _workerIds.length;
    final inFlightCount = {
      ..._workerLeases.values,
      ..._successReservations.values,
    }.length;
    final suspendedTaskCount =
        _suspendedLeases.map((lease) => lease.taskNumber).toSet().length;
    final abandonedTaskCount = taskCount > 0 && allWorkersPaused
        ? taskCount - _completedTasks.length - suspendedTaskCount
        : _cancelledTasks.length;
    return GenerationSchedulerStatus(
      inFlightCount: inFlightCount,
      completedTaskCount: _completedTasks.length,
      suspendedTaskCount: suspendedTaskCount,
      stopRequested: _stopRequested,
      finished: (_stopRequested && inFlightCount == 0) ||
          (taskCount > 0 &&
              _completedTasks.length +
                      suspendedTaskCount +
                      _cancelledTasks.length ==
                  taskCount &&
              inFlightCount == 0) ||
          (allWorkersPaused && inFlightCount == 0),
      allWorkersPaused: allWorkersPaused,
      abandonedTaskCount: abandonedTaskCount,
    );
  }
}
