// PR2.8.D.3 — OperationalLog contract tests.
//
// Pins the operational-log invariants the timeline UI + on-
// device debugging now depend on:
//
//   1. Ring buffer caps at maxEntries (oldest dropped).
//   2. JSONL persist/restore round-trips losslessly.
//   3. Malformed JSONL lines are skipped, not fatal — boot
//      must NEVER fail because a prior timeline file got
//      partially-written by a hard kill.
//   4. Missing JSONL file is silently tolerated.
//   5. Boundary rows survive serialization with their special
//      tag intact.
//   6. exportText() / formatEvent() shape matches the
//      `[HH:MM:SS.mmm] [tag] message` contract.

import 'dart:io';

import 'package:companion_ios/src/services/operational_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => OperationalLog.clear());

  test('emit + boundary append to the ring buffer in order', () {
    OperationalLog.emit('boot', 'starting up');
    OperationalLog.boundary('app launch');
    OperationalLog.emit('generation', 'activate abc123');

    final events = OperationalLog.events.value;
    expect(events.length, 3);
    expect(events[0].tag, 'boot');
    expect(events[0].message, 'starting up');
    expect(events[1].tag, OperationalLog.sessionTag);
    expect(events[1].message, 'app launch');
    expect(events[2].tag, 'generation');
  });

  test('ring buffer caps at maxEntries (oldest dropped)', () {
    for (var i = 0; i < OperationalLog.maxEntries + 50; i++) {
      OperationalLog.emit('boot', 'msg $i');
    }
    expect(OperationalLog.events.value.length, OperationalLog.maxEntries);
    // First surviving entry should be the 50th emit (the 49 before
    // it were dropped to make room).
    expect(
      OperationalLog.events.value.first.message,
      'msg 50',
    );
    expect(
      OperationalLog.events.value.last.message,
      'msg ${OperationalLog.maxEntries + 49}',
    );
  });

  test('formatEvent matches the [HH:MM:SS.mmm] [tag] message contract', () {
    final e = OperationalEvent(
      timestamp: DateTime(2026, 5, 18, 14, 23, 18, 142),
      tag: 'engine',
      message: 'setSource /docs/inventory_files/abc/dev-track-a.wav',
    );
    expect(
      OperationalLog.formatEvent(e),
      '[14:23:18.142] [engine] '
      'setSource /docs/inventory_files/abc/dev-track-a.wav',
    );
  });

  test('formatEvent decorates session boundaries with em dashes', () {
    final e = OperationalEvent(
      timestamp: DateTime(2026, 5, 18, 14, 23, 18, 142),
      tag: OperationalLog.sessionTag,
      message: 'app launch',
    );
    expect(
      OperationalLog.formatEvent(e),
      '[14:23:18.142] [session] ──── app launch ────',
    );
  });

  test('persistTo + restoreFrom round-trip preserves order, tag, message',
      () async {
    OperationalLog.emit('boot', 'starting');
    OperationalLog.boundary('app launch');
    OperationalLog.emit('generation', 'activate abc');
    OperationalLog.emit('engine', 'setSource /tmp/a.wav');
    final before = List.of(OperationalLog.events.value);

    final tmp = await Directory.systemTemp.createTemp('opslog');
    final path = '${tmp.path}/timeline.jsonl';
    try {
      await OperationalLog.persistTo(path);
      OperationalLog.clear();
      expect(OperationalLog.events.value, isEmpty);
      await OperationalLog.restoreFrom(path);
      final after = OperationalLog.events.value;
      expect(after.length, before.length);
      for (var i = 0; i < before.length; i++) {
        expect(after[i].tag, before[i].tag);
        expect(after[i].message, before[i].message);
        // Round-trip via ISO-8601 is millisecond-precision —
        // microseconds are dropped, but the timestamp authority
        // for timelines is ms anyway.
        expect(
          after[i].timestamp.millisecondsSinceEpoch,
          before[i].timestamp.millisecondsSinceEpoch,
        );
      }
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('restoreFrom silently tolerates a missing file', () async {
    final tmp = await Directory.systemTemp.createTemp('opslog_missing');
    try {
      await OperationalLog.restoreFrom('${tmp.path}/does_not_exist.jsonl');
      expect(OperationalLog.events.value, isEmpty);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('restoreFrom skips malformed JSONL lines, keeps good ones', () async {
    final tmp = await Directory.systemTemp.createTemp('opslog_malformed');
    final path = '${tmp.path}/timeline.jsonl';
    try {
      // Mix of: valid, malformed JSON, JSON-but-missing-fields,
      // valid again. Restore must extract the two good rows.
      final lines = [
        '{"ts":"2026-05-18T14:23:18.142Z","tag":"boot","message":"row 1"}',
        'this is not json',
        '{"ts":"NOT-A-DATE","tag":"x","message":"row bad"}',
        '{"ts":"2026-05-18T14:23:19.000Z","tag":"engine","message":"row 2"}',
        '',
      ];
      await File(path).writeAsString('${lines.join("\n")}\n');
      await OperationalLog.restoreFrom(path);
      final restored = OperationalLog.events.value;
      expect(restored.length, 2);
      expect(restored[0].message, 'row 1');
      expect(restored[1].message, 'row 2');
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('restoreFrom appends restored rows BEFORE live in-memory rows',
      () async {
    OperationalLog.emit('boot', 'live row');
    final tmp = await Directory.systemTemp.createTemp('opslog_append');
    final path = '${tmp.path}/timeline.jsonl';
    try {
      const canonical =
          '{"ts":"2026-05-18T14:00:00.000Z","tag":"engine","message":"persisted row"}\n';
      await File(path).writeAsString(canonical);

      await OperationalLog.restoreFrom(path);
      final events = OperationalLog.events.value;
      expect(events.length, 2);
      expect(events[0].message, 'persisted row'); // restored prepended
      expect(events[1].message, 'live row');      // in-memory preserved
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('exportText joins all rows newline-separated in canonical shape',
      () {
    OperationalLog.emit('boot', 'first');
    OperationalLog.boundary('app launch');
    OperationalLog.emit('engine', 'play');

    final text = OperationalLog.exportText();
    final lines = text.split('\n');
    expect(lines.length, 3);
    expect(lines[0], contains('[boot] first'));
    expect(lines[1], contains('[session] ──── app launch ────'));
    expect(lines[2], contains('[engine] play'));
  });
}
