// Sync chaos simulator — runner.
//
// One test per named scenario. Each test:
//   1. Boots a fresh simulator (in-memory DB, all layers wired).
//   2. Runs the scenario's seed + drive script (drive() may
//      legitimately throw — some scenarios test that the
//      desktop REFUSES illegal operations).
//   3. Walks the invariant list, capturing pass/fail per item.
//   4. Asserts every invariant passed; on failure, the test's
//      output includes the timeline + per-invariant report so
//      a regression points directly at the broken contract.
//
// New scenarios + invariants slot in by adding to the lists
// below — no per-scenario test wiring needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';

import 'sync_simulator/scenarios.dart';
import 'sync_simulator/sync_simulator.dart';

void main() {
  // Concrete scenario fixtures — chaos playbook. Add new
  // scenarios here; the test runner picks them up automatically.
  final scenarios = <SyncScenario>[
    HappyPathBaseline(),
    NetworkDropMidTransfer(),
    DuplicateTelemetryReplay(),
    IllegalCancelDuringTelemetryRejected(),
    SessionInFlightRejection(),
  ];

  group('Sync chaos simulator', () {
    for (final scenario in scenarios) {
      test(scenario.name, () async {
        final result = await SyncSimulator.run(scenario);
        if (!result.allInvariantsPassed) {
          // Print the full report — timeline + per-invariant
          // outcome — before failing so the diff log points at
          // the broken contract.
          // ignore: avoid_print
          print(result.formatReport());
        }
        expect(
          result.allInvariantsPassed,
          isTrue,
          reason: '\n${result.formatReport()}',
        );
      });
    }

    test('happy path timeline walks the canonical spine', () async {
      final result = await SyncSimulator.run(HappyPathBaseline());
      // The spine: every successful sync visits exactly these
      // states, in this order. Drift here would mean the state
      // machine quietly grew an extra transition or skipped
      // one.
      expect(
        result.timeline,
        equals([
          SyncState.negotiating,
          SyncState.approving,
          SyncState.preparingManifest,
          SyncState.transferring,
          SyncState.receivingTelemetry,
          SyncState.applyingTelemetry,
          SyncState.finalizingRotation,
          SyncState.rotationComplete,
        ]),
      );
    });

    test('network drop timeline ends at networkLost terminal',
        () async {
      final result = await SyncSimulator.run(NetworkDropMidTransfer());
      expect(result.timeline.last, SyncState.networkLost);
      // Must NOT have reached receivingTelemetry or beyond —
      // the drop happened during transfer.
      expect(
        result.timeline,
        isNot(contains(SyncState.receivingTelemetry)),
      );
    });
  });
}
