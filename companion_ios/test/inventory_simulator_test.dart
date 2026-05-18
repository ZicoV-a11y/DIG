// PR2.8.A.simulator — phone-side inventory chaos test runner.
//
// One test per named scenario. Each runs the full
// seed → drive → invariant sweep cycle and asserts every
// invariant passed (or, for "expect-fires" meta-invariants,
// that the wrapped invariant correctly detected injected
// drift). New scenarios slot in by appending to the list.

import 'package:flutter_test/flutter_test.dart';

import 'inventory_simulator/inventory_simulator.dart';
import 'inventory_simulator/scenarios.dart';

void main() {
  final scenarios = <InventoryScenario>[
    ActivationAtomicBaseline(),
    ActivationInterruptedDriftDetected(),
    GenerationHashMismatch(),
    ResumeAfterCrash(),
    StagedGenerationOrphaned(),
  ];

  group('Inventory chaos simulator', () {
    for (final scenario in scenarios) {
      test(scenario.name, () async {
        final result = await InventorySimulator.run(scenario);
        if (!result.allInvariantsPassed) {
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
  });
}
