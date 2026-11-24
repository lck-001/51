import 'dart:async';

final class ClientRetirementException implements Exception {
  const ClientRetirementException();
  @override
  String toString() => 'ClientRetirementException(cleanupUnconfirmed)';
}

/// App-owned retirement only: every admission callback executes synchronously
/// through Future.sync; one failure never skips other gates or accepted drains.
final class ClientRetirement {
  ClientRetirement({
    required List<FutureOr<void> Function()> admissions,
    required List<FutureOr<void> Function()> drains,
  }) : _admissions = List.unmodifiable(admissions),
       _drains = List.unmodifiable(drains);
  final List<FutureOr<void> Function()> _admissions, _drains;
  Future<void>? _completion;
  void retire() {
    if (_completion != null) return;
    final done = Completer<void>();
    _completion = done.future;
    done.future.ignore();
    final actions = <Future<void>>[];
    for (final action in [..._admissions, ..._drains]) {
      final work = Future<void>.sync(action);
      work.ignore();
      actions.add(work);
    }
    () async {
      var failed = false;
      await Future.wait(
        actions.map(
          (work) => work.catchError((Object _) {
            failed = true;
          }),
        ),
      );
      if (failed) {
        done.completeError(const ClientRetirementException());
      } else {
        done.complete();
      }
    }().ignore();
  }

  Future<void> get completion {
    retire();
    return _completion!;
  }
}
