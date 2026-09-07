import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_scheduler.dart';

void main() {
  test('finite tasks are claimed once and a busy worker cannot claim again',
      () {
    final scheduler = GenerationScheduler(
      taskCount: 3,
      workerIds: const ['A', 'B', 'C'],
    );

    final first = scheduler.claim('A');
    final second = scheduler.claim('B');
    final third = scheduler.claim('C');

    expect(first?.taskNumber, 1);
    expect(second?.taskNumber, 2);
    expect(third?.taskNumber, 3);
    expect(scheduler.claim('A'), isNull);
    expect(
      {first?.taskNumber, second?.taskNumber, third?.taskNumber},
      {1, 2, 3},
    );
    expect(scheduler.status.inFlightCount, 3);
  });

  test('a failed task returns to the front and another worker can retry it',
      () {
    final scheduler = GenerationScheduler(
      taskCount: 3,
      workerIds: const ['A', 'B'],
    );

    final failedLease = scheduler.claim('A')!;
    final secondTask = scheduler.claim('B')!;
    scheduler.completeFailure(failedLease);
    scheduler.reserveSuccess(secondTask);
    scheduler.completeSuccess(secondTask);

    final retry = scheduler.claim('B');

    expect(retry?.taskNumber, failedLease.taskNumber);
    expect(retry?.attemptNumber, failedLease.attemptNumber + 1);
    expect(retry?.workerId, 'B');
  });

  test('only the first successful result may cross the persistence seam', () {
    final scheduler = GenerationScheduler(
      taskCount: 1,
      workerIds: const ['A', 'B'],
    );

    final firstAttempt = scheduler.claim('A')!;
    scheduler.completeFailure(firstAttempt);
    final retry = scheduler.claim('B')!;

    expect(scheduler.reserveSuccess(firstAttempt), isTrue);
    expect(scheduler.reserveSuccess(retry), isFalse);
    expect(scheduler.completeSuccess(firstAttempt), isTrue);
    expect(scheduler.completeSuccess(retry), isFalse);
    expect(scheduler.status.completedTaskCount, 1);
  });

  test('a reserved paid response cannot be reopened as generation failure', () {
    final scheduler = GenerationScheduler(
      taskCount: 1,
      workerIds: const ['A', 'B'],
    );

    final firstAttempt = scheduler.claim('A')!;
    scheduler.completeFailure(firstAttempt);
    final retry = scheduler.claim('B')!;

    expect(scheduler.reserveSuccess(firstAttempt), isTrue);
    expect(() => scheduler.completeFailure(firstAttempt), throwsStateError);
    expect(scheduler.reserveSuccess(retry), isFalse);
    expect(scheduler.completeSuccess(firstAttempt), isTrue);
    expect(scheduler.status.completedTaskCount, 1);
  });

  test('a reserved response can release its API worker before completion', () {
    final scheduler = GenerationScheduler(
      taskCount: 2,
      workerIds: const ['A'],
    );
    final persistence = scheduler.claim('A')!;
    expect(scheduler.reserveSuccess(persistence), isTrue);

    expect(scheduler.detachWorkerForPersistence(persistence), isTrue);
    final nextApiRequest = scheduler.claim('A');

    expect(nextApiRequest?.taskNumber, 2);
    expect(scheduler.status.completedTaskCount, 0);
    expect(scheduler.status.inFlightCount, 2);
    expect(scheduler.completeSuccess(persistence), isTrue);
    expect(scheduler.status.completedTaskCount, 1);
    expect(scheduler.status.inFlightCount, 1);
  });

  test('a lease not issued by the scheduler cannot complete a task', () {
    final scheduler = GenerationScheduler(
      taskCount: 1,
      workerIds: const ['A'],
    );
    scheduler.claim('A');
    const forged = GenerationLease(
      taskNumber: 1,
      attemptNumber: 1,
      workerId: 'A',
    );

    expect(scheduler.completeSuccess(forged), isFalse);
    expect(scheduler.status.completedTaskCount, 0);
    expect(scheduler.status.inFlightCount, 1);
  });

  test('a late failure cannot reopen a task after another attempt succeeds',
      () {
    final scheduler = GenerationScheduler(
      taskCount: 1,
      workerIds: const ['A', 'B'],
    );
    final firstAttempt = scheduler.claim('A')!;
    scheduler.completeFailure(firstAttempt);
    final retry = scheduler.claim('B')!;

    scheduler.reserveSuccess(firstAttempt);
    scheduler.completeSuccess(firstAttempt);
    expect(scheduler.status.finished, isFalse);
    scheduler.completeFailure(retry);

    expect(scheduler.claim('A'), isNull);
    expect(scheduler.status.completedTaskCount, 1);
    expect(scheduler.status.finished, isTrue);
  });

  test(
      'a success resets failures and the fifth consecutive failure pauses worker',
      () {
    final scheduler = GenerationScheduler(
      taskCount: 0,
      workerIds: const ['A'],
    );

    for (var failure = 0; failure < 4; failure++) {
      scheduler.completeFailure(scheduler.claim('A')!);
    }
    final successfulLease = scheduler.claim('A')!;
    scheduler.reserveSuccess(successfulLease);
    scheduler.completeSuccess(successfulLease);

    for (var failure = 0; failure < 4; failure++) {
      scheduler.completeFailure(scheduler.claim('A')!);
    }
    final fifthFailure = scheduler.claim('A')!;
    scheduler.completeFailure(fifthFailure);

    expect(scheduler.claim('A'), isNull);
    expect(scheduler.status.allWorkersPaused, isTrue);
  });

  test('an older saved success does not erase newer worker failures', () {
    final scheduler = GenerationScheduler(taskCount: 0, workerIds: ['A']);
    final old = scheduler.claim('A')!;
    scheduler.reserveSuccess(old);
    scheduler.detachWorkerForPersistence(old);
    scheduler.completeFailure(scheduler.claim('A')!);
    scheduler.completeSuccess(old);
    for (var failure = 0; failure < 4; failure++) {
      scheduler.completeFailure(scheduler.claim('A')!);
    }
    expect(scheduler.status.allWorkersPaused, isTrue);
  });

  test(
      'unknown task is quarantined while healthy accounts finish untouched tasks',
      () {
    final scheduler = GenerationScheduler(taskCount: 3, workerIds: ['A', 'B']);
    final unknown = scheduler.claim('A')!;
    expect(scheduler.suspendOutcome(unknown), isTrue);
    expect(scheduler.claim('A'), isNull);
    expect(scheduler.status.inFlightCount, 0);
    for (final number in [2, 3]) {
      final lease = scheduler.claim('B')!;
      expect(lease.taskNumber, number);
      scheduler.reserveSuccess(lease);
      scheduler.completeSuccess(lease);
    }
    expect(scheduler.status.suspendedTaskCount, 1);
    expect(scheduler.status.completedTaskCount, 2);
    expect(scheduler.status.finished, isTrue);
  });

  test(
      'an account rejection pauses immediately and gives the task to a healthy account',
      () {
    final scheduler = GenerationScheduler(taskCount: 1, workerIds: ['A', 'B']);
    final rejected = scheduler.claim('A')!;
    final failure = scheduler.completeFailure(rejected, pauseWorker: true);
    expect(failure.workerPaused, isTrue);
    expect(failure.consecutiveFailureCount, 1);
    expect(failure.taskRequeued, isTrue);
    expect(scheduler.claim('A'), isNull);
    expect(scheduler.claim('B')?.taskNumber, 1);
  });

  test('cancelling an unsent task finishes without retry or account penalty',
      () {
    final scheduler = GenerationScheduler(taskCount: 1, workerIds: ['A']);
    final unsent = scheduler.claim('A')!;
    expect(scheduler.cancel(unsent), isTrue);
    expect(scheduler.status.inFlightCount, 0);
    expect(scheduler.status.allWorkersPaused, isFalse);
    expect(scheduler.status.finished, isTrue);
    expect(scheduler.status.abandonedTaskCount, 1);
    expect(scheduler.claim('A'), isNull);
    expect(scheduler.reserveSuccess(unsent), isFalse);
    expect(scheduler.cancel(unsent), isFalse);
  });

  test('late unknown success preserves a newer lease and its account failure',
      () {
    final scheduler = GenerationScheduler(taskCount: 2, workerIds: ['A', 'B']);
    final old = scheduler.claim('A')!;
    scheduler.suspendOutcome(old, pauseWorker: false);
    final newer = scheduler.claim('A')!;
    expect(scheduler.reserveSuccess(old), isTrue);
    expect(scheduler.detachWorkerForPersistence(old), isTrue);
    expect(scheduler.claim('A'), isNull,
        reason: 'The newer request still owns A.');
    expect(scheduler.completeFailure(newer, pauseWorker: true).workerPaused,
        isTrue);
    expect(scheduler.completeSuccess(old), isTrue);
    expect(scheduler.claim('A'), isNull,
        reason: 'The late success must not re-enable rejected A.');
    expect(scheduler.status.suspendedTaskCount, 0);
    final retry = scheduler.claim('B')!;
    expect(retry.taskNumber, 2);
    scheduler.reserveSuccess(retry);
    scheduler.completeSuccess(retry);
    expect(scheduler.status.finished, isTrue);
    expect(scheduler.status.completedTaskCount, 2);
  });

  test('late success after a suspended batch finishes is accepted exactly once',
      () {
    final scheduler = GenerationScheduler(taskCount: 1, workerIds: ['A']);
    final old = scheduler.claim('A')!;
    scheduler.suspendOutcome(old);
    expect(scheduler.status.finished, isTrue);
    expect(scheduler.status.suspendedTaskCount, 1);
    expect(scheduler.status.abandonedTaskCount, 0);
    expect(scheduler.reserveSuccess(old), isTrue);
    expect(scheduler.status.inFlightCount, 1);
    expect(scheduler.detachWorkerForPersistence(old), isTrue);
    expect(scheduler.completeSuccess(old), isTrue);
    expect(scheduler.status.suspendedTaskCount, 0);
    expect(scheduler.status.completedTaskCount, 1);
    expect(scheduler.reserveSuccess(old), isFalse);
    expect(scheduler.completeSuccess(old), isFalse);
  });

  test('definitely-unsent cancellation never discards an unknown paid request',
      () {
    final scheduler = GenerationScheduler(taskCount: 1, workerIds: ['A']);
    final unknown = scheduler.claim('A')!;
    scheduler.suspendOutcome(unknown);
    expect(scheduler.cancel(unknown), isFalse);
    expect(scheduler.reserveSuccess(unknown), isTrue);
    expect(scheduler.completeSuccess(unknown), isTrue);
  });

  test('duplicate suspension does not pause a newer request on that worker',
      () {
    final scheduler = GenerationScheduler(taskCount: 2, workerIds: ['A']);
    final old = scheduler.claim('A')!;
    scheduler.suspendOutcome(old, pauseWorker: false);
    final newer = scheduler.claim('A')!;
    expect(scheduler.suspendOutcome(old), isTrue);
    expect(scheduler.status.allWorkersPaused, isFalse);
    expect(scheduler.status.inFlightCount, 1);
    scheduler.reserveSuccess(newer);
    scheduler.completeSuccess(newer);
  });

  test('stop blocks new claims and finishes after in-flight work settles', () {
    final scheduler = GenerationScheduler(
      taskCount: 3,
      workerIds: const ['A', 'B'],
    );
    final inFlight = scheduler.claim('A')!;

    scheduler.requestStop();

    expect(scheduler.claim('B'), isNull);
    expect(scheduler.status.stopRequested, isTrue);
    expect(scheduler.status.finished, isFalse);

    scheduler.reserveSuccess(inFlight);
    scheduler.completeSuccess(inFlight);

    expect(scheduler.status.finished, isTrue);
  });

  test('finite batch finishes only after every logical task succeeds', () {
    final scheduler = GenerationScheduler(
      taskCount: 2,
      workerIds: const ['A', 'B'],
    );
    final first = scheduler.claim('A')!;
    final second = scheduler.claim('B')!;

    scheduler.reserveSuccess(first);
    scheduler.completeSuccess(first);
    expect(scheduler.status.finished, isFalse);

    scheduler.reserveSuccess(second);
    scheduler.completeSuccess(second);
    expect(scheduler.status.finished, isTrue);
    expect(scheduler.status.completedTaskCount, 2);
    expect(scheduler.status.abandonedTaskCount, 0);
  });

  test('finite batch abandons unfinished tasks when every worker is paused',
      () {
    final scheduler = GenerationScheduler(
      taskCount: 3,
      workerIds: const ['A'],
    );

    for (var failure = 0; failure < 5; failure++) {
      scheduler.completeFailure(scheduler.claim('A')!);
    }

    expect(scheduler.status.allWorkersPaused, isTrue);
    expect(scheduler.status.finished, isTrue);
    expect(scheduler.status.abandonedTaskCount, 3);
  });

  test('unlimited batch finishes when every worker is paused', () {
    final scheduler = GenerationScheduler(
      taskCount: 0,
      workerIds: const ['A'],
    );

    for (var failure = 0; failure < 5; failure++) {
      scheduler.completeFailure(scheduler.claim('A')!);
    }

    expect(scheduler.status.allWorkersPaused, isTrue);
    expect(scheduler.status.finished, isTrue);
    expect(scheduler.status.abandonedTaskCount, 0);
  });
}
