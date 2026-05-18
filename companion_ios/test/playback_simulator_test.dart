// PR2.8.C.simulator — playback continuity chaos runner.

import 'package:flutter_test/flutter_test.dart';

import 'playback_simulator/playback_simulator.dart';
import 'playback_simulator/scenarios.dart';

void main() {
  final scenarios = <PlaybackScenario>[
    GenerationSwappedDuringPausedPlayback(),
    CurrentlyPlayingRetiredKeepsPlaying(),
    SyncBeginsDuringPausedState(),
    RestoreAfterGenerationGc(),
    DoubleGenerationRotationBeforeRestore(),
  ];

  group('Playback chaos simulator', () {
    for (final scenario in scenarios) {
      test(scenario.name, () async {
        final result = await PlaybackSimulator.run(scenario);
        if (!result.allInvariantsPassed || result.driveError != null) {
          // ignore: avoid_print
          print(result.formatReport());
        }
        if (result.driveError != null) {
          fail(
            'scenario drive raised: ${result.driveError}\n'
            '${result.formatReport()}',
          );
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
