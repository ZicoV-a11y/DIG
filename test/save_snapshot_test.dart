import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/save_snapshot.dart';

/// Filename format is locked — these tests are the executable
/// spec. Any change to the shape has to update the tests AND
/// every save the user has on disk, so don't reshape without a
/// migration story.
void main() {
  group('SaveSnapshot.formatFilename — round-trip', () {
    test('PM time renders 12-hour with PM suffix', () {
      final name = SaveSnapshot.formatFilename(
        libraryName: 'AFRO_LIBRARY',
        machineId: 'DJMAC',
        capturedAt: DateTime(2026, 5, 12, 18, 47),
      );
      expect(name, 'AFRO_LIBRARY__DJMAC__2026-MAY-12__06-47PM.library');
    });

    test('AM time renders 12-hour with AM suffix', () {
      final name = SaveSnapshot.formatFilename(
        libraryName: 'ZCRATE',
        machineId: 'MBP14',
        capturedAt: DateTime(2026, 5, 12, 2, 15),
      );
      expect(name, 'ZCRATE__MBP14__2026-MAY-12__02-15AM.library');
    });

    test('midnight → 12-00AM, noon → 12-00PM', () {
      final mid = SaveSnapshot.formatFilename(
        libraryName: 'L',
        machineId: 'M',
        capturedAt: DateTime(2026, 5, 12, 0, 0),
      );
      final noon = SaveSnapshot.formatFilename(
        libraryName: 'L',
        machineId: 'M',
        capturedAt: DateTime(2026, 5, 12, 12, 0),
      );
      expect(mid, contains('__12-00AM.library'));
      expect(noon, contains('__12-00PM.library'));
    });
  });

  group('SaveSnapshot.formatFilename — sanitisation', () {
    test('spaces become underscores, runs collapse', () {
      final name = SaveSnapshot.formatFilename(
        libraryName: 'My  Cool   Library',
        machineId: 'mac-book',
        capturedAt: DateTime(2026, 5, 12, 14, 0),
      );
      // Spaces → underscores, runs collapsed, hyphen replaced too
      // (only alphanumerics survive). Library / machine fields are
      // uppercased.
      expect(name.startsWith('MY_COOL_LIBRARY__MAC_BOOK__'), isTrue);
    });

    test('empty input falls back to "LIBRARY" / "MACHINE"', () {
      final name = SaveSnapshot.formatFilename(
        libraryName: '',
        machineId: '!!!',
        capturedAt: DateTime(2026, 5, 12, 14, 0),
      );
      // Each field has its own emptyFallback now: library → "LIBRARY",
      // machine → "MACHINE". Keeps the two slots distinguishable in
      // the filename even when both inputs sanitise to nothing.
      expect(name.startsWith('LIBRARY__MACHINE__'), isTrue);
    });
  });

  group('SaveSnapshot.tryParse', () {
    test('parses a well-formed filename', () {
      final s = SaveSnapshot.tryParse(
        'AFRO_LIBRARY__DJMAC__2026-MAY-12__06-47PM.library',
      );
      expect(s, isNotNull);
      expect(s!.libraryName, 'AFRO_LIBRARY');
      expect(s.machineId, 'DJMAC');
      expect(s.capturedAt, DateTime(2026, 5, 12, 18, 47));
    });

    test('round-trips format → parse → format', () {
      final original = DateTime(2026, 5, 12, 2, 15);
      final name = SaveSnapshot.formatFilename(
        libraryName: 'ZCRATE',
        machineId: 'MBP14',
        capturedAt: original,
      );
      final parsed = SaveSnapshot.tryParse(name);
      expect(parsed, isNotNull);
      expect(parsed!.capturedAt, original);
      final reFormatted = SaveSnapshot.formatFilename(
        libraryName: parsed.libraryName,
        machineId: parsed.machineId,
        capturedAt: parsed.capturedAt,
      );
      expect(reFormatted, name);
    });

    test('rejects wrong extension', () {
      final s = SaveSnapshot.tryParse(
        'AFRO_LIBRARY__DJMAC__2026-MAY-12__06-47PM.txt',
      );
      expect(s, isNull);
    });

    test('rejects unknown month abbreviation', () {
      final s = SaveSnapshot.tryParse(
        'AFRO__DJMAC__2026-XXX-12__06-47PM.library',
      );
      expect(s, isNull);
    });

    test('rejects malformed time', () {
      final s = SaveSnapshot.tryParse(
        'AFRO__DJMAC__2026-MAY-12__13-99XX.library',
      );
      expect(s, isNull);
    });

    test('rejects missing field separator', () {
      // Only 3 fields (no machine ID after __).
      final s = SaveSnapshot.tryParse(
        'AFRO__2026-MAY-12__06-47PM.library',
      );
      expect(s, isNull);
    });

    test('rejects partial file written mid-snapshot', () {
      // The manager writes `[name].partial` while copying then
      // renames to the final name. The .partial file must never
      // be confused for a real snapshot.
      final s = SaveSnapshot.tryParse(
        'AFRO__DJMAC__2026-MAY-12__06-47PM.library.partial',
      );
      expect(s, isNull);
    });
  });
}
