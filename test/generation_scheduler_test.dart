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

  test('a failed persistence releases the success reservation for a retry', () {
    final scheduler = GenerationScheduler(
      taskCount: 1,
      workerIds: const ['A', 'B'],
    );

    final firstAttempt = scheduler.claim('A')!;
    scheduler.completeFailure(firstAttempt);
    final retry = scheduler.claim('B')!;

    expect(scheduler.reserveSuccess(firstAttempt), isTrue);
    final persistenceFailure = scheduler.completeFailure(firstAttempt);
    expect(persistenceFailure.taskRequeued, isTrue);
    expect(scheduler.reserveSuccess(retry), isTrue);
    expect(scheduler.completeSuccess(retry), isTrue);
    expect(scheduler.status.completedTaskCount, 1);
  });

  test('a reserved persistence can release its API worker without completing',
      () {
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
