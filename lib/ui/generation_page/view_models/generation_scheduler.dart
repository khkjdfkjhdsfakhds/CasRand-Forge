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
  });

  final int inFlightCount;
  final int completedTaskCount;
  final bool stopRequested;
  final bool finished;
  final bool allWorkersPaused;
  final int abandonedTaskCount;
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
  final ListQueue<int> _retryQueue = ListQueue<int>();
  final Map<int, int> _taskAttemptNumbers = {};
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
    _issuedLeases.add(lease);
    return lease;
  }

  /// Reserves the right to persist the first successful result for a task.
  bool reserveSuccess(GenerationLease lease) {
    if (!_issuedLeases.contains(lease)) return false;
    final reserved = _successReservations[lease.taskNumber];
    if (_completedTasks.contains(lease.taskNumber) ||
        (reserved != null && !identical(reserved, lease))) {
      _discardLease(lease);
      return false;
    }
    _successReservations[lease.taskNumber] = lease;
    _retryQueue.removeWhere((taskNumber) => taskNumber == lease.taskNumber);
    return true;
  }

  /// Releases only the API-worker slot after a successful response has
  /// reserved persistence ownership. The logical task remains in flight until
  /// [completeSuccess] or [completeFailure] settles its storage operation.
  bool detachWorkerForPersistence(GenerationLease lease) {
    if (!identical(_successReservations[lease.taskNumber], lease) ||
        !identical(_workerLeases[lease.workerId], lease) ||
        !_issuedLeases.contains(lease)) {
      return false;
    }
    _workerLeases.remove(lease.workerId);
    return true;
  }

  /// Completes a reserved result after it has been persisted successfully.
  bool completeSuccess(GenerationLease lease) {
    if (!identical(_successReservations[lease.taskNumber], lease)) {
      return false;
    }
    _successReservations.remove(lease.taskNumber);
    if (!_issuedLeases.remove(lease)) return false;
    if (identical(_workerLeases[lease.workerId], lease)) {
      _workerLeases.remove(lease.workerId);
    }
    if (!_taskAttemptNumbers.containsKey(lease.taskNumber) ||
        !_completedTasks.add(lease.taskNumber)) {
      return false;
    }
    _workerFailureCounts[lease.workerId] = 0;
    _pausedWorkers.remove(lease.workerId);
    _retryQueue.removeWhere((taskNumber) => taskNumber == lease.taskNumber);
    _issuedLeases.removeWhere(
      (issued) =>
          issued.taskNumber == lease.taskNumber &&
          !identical(_workerLeases[issued.workerId], issued),
    );
    return true;
  }

  GenerationFailureResult completeFailure(GenerationLease lease) {
    final isCurrentWorkerLease =
        identical(_workerLeases[lease.workerId], lease);
    final isReservedSuccess =
        identical(_successReservations[lease.taskNumber], lease);
    if (!isCurrentWorkerLease && !isReservedSuccess) {
      return GenerationFailureResult(
        consecutiveFailureCount: _workerFailureCounts[lease.workerId] ?? 0,
        workerPaused: _pausedWorkers.contains(lease.workerId),
        taskRequeued: false,
      );
    }
    if (isCurrentWorkerLease) _workerLeases.remove(lease.workerId);
    if (isReservedSuccess) {
      _successReservations.remove(lease.taskNumber);
      _issuedLeases.remove(lease);
    }
    final failureCount = (_workerFailureCounts[lease.workerId] ?? 0) + 1;
    _workerFailureCounts[lease.workerId] = failureCount;
    if (failureCount >= 5) {
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

  void requestStop() {
    _stopRequested = true;
  }

  void _discardLease(GenerationLease lease) {
    _issuedLeases.remove(lease);
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
    final abandonedTaskCount = taskCount > 0 && allWorkersPaused
        ? taskCount - _completedTasks.length
        : 0;
    return GenerationSchedulerStatus(
      inFlightCount: inFlightCount,
      completedTaskCount: _completedTasks.length,
      stopRequested: _stopRequested,
      finished: (_stopRequested && inFlightCount == 0) ||
          (taskCount > 0 &&
              _completedTasks.length == taskCount &&
              inFlightCount == 0) ||
          (allWorkersPaused && inFlightCount == 0),
      allWorkersPaused: allWorkersPaused,
      abandonedTaskCount: abandonedTaskCount,
    );
  }
}
