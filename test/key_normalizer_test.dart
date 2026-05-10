import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/utils/key_normalizer.dart';

void main() {
  group('normalizeKeyToCamelot', () {
    test('returns null for null/empty/whitespace', () {
      expect(normalizeKeyToCamelot(null), isNull);
      expect(normalizeKeyToCamelot(''), isNull);
      expect(normalizeKeyToCamelot('   '), isNull);
    });

    group('musical notation', () {
      test('user-spec examples', () {
        expect(normalizeKeyToCamelot('Dm'), '7A');
        expect(normalizeKeyToCamelot('Fm'), '4A');
        expect(normalizeKeyToCamelot('D'), '10B');
        expect(normalizeKeyToCamelot('A#m'), '3A');
        expect(normalizeKeyToCamelot('F#m'), '11A');
        expect(normalizeKeyToCamelot('Bb'), '6B');
      });

      test('all naturals — major', () {
        expect(normalizeKeyToCamelot('C'), '8B');
        expect(normalizeKeyToCamelot('G'), '9B');
        expect(normalizeKeyToCamelot('D'), '10B');
        expect(normalizeKeyToCamelot('A'), '11B');
        expect(normalizeKeyToCamelot('E'), '12B');
        expect(normalizeKeyToCamelot('B'), '1B');
        expect(normalizeKeyToCamelot('F'), '7B');
      });

      test('all naturals — minor', () {
        expect(normalizeKeyToCamelot('Am'), '8A');
        expect(normalizeKeyToCamelot('Em'), '9A');
        expect(normalizeKeyToCamelot('Bm'), '10A');
        expect(normalizeKeyToCamelot('Fm'), '4A');
        expect(normalizeKeyToCamelot('Cm'), '5A');
        expect(normalizeKeyToCamelot('Gm'), '6A');
        expect(normalizeKeyToCamelot('Dm'), '7A');
      });

      test('sharp / flat enharmonic equivalents', () {
        expect(normalizeKeyToCamelot('F#'), '2B');
        expect(normalizeKeyToCamelot('Gb'), '2B');
        expect(normalizeKeyToCamelot('C#'), '3B');
        expect(normalizeKeyToCamelot('Db'), '3B');
        expect(normalizeKeyToCamelot('G#m'), '1A');
        expect(normalizeKeyToCamelot('Abm'), '1A');
        expect(normalizeKeyToCamelot('Bbm'), '3A');
        expect(normalizeKeyToCamelot('A#m'), '3A');
      });

      test('lowercase and mixed case', () {
        expect(normalizeKeyToCamelot('dm'), '7A');
        expect(normalizeKeyToCamelot('c#m'), '12A');
        expect(normalizeKeyToCamelot('bb'), '6B');
        expect(normalizeKeyToCamelot('f#'), '2B');
      });

      test('unicode accidentals', () {
        expect(normalizeKeyToCamelot('B♭'), '6B');
        expect(normalizeKeyToCamelot('F♯m'), '11A');
        expect(normalizeKeyToCamelot('B ♭ m'), '3A');
      });

      test('explicit min/maj suffixes', () {
        expect(normalizeKeyToCamelot('Dmin'), '7A');
        expect(normalizeKeyToCamelot('Dmaj'), '10B');
        expect(normalizeKeyToCamelot('Bbmin'), '3A');
        expect(normalizeKeyToCamelot('C#min'), '12A');
      });

      test('non-key strings return null', () {
        expect(normalizeKeyToCamelot('Cmaj7'), isNull);
        expect(normalizeKeyToCamelot('xyz'), isNull);
        expect(normalizeKeyToCamelot('H'), isNull);
        expect(normalizeKeyToCamelot('m'), isNull);
      });
    });

    group('Camelot notation', () {
      test('passthrough', () {
        expect(normalizeKeyToCamelot('8A'), '8A');
        expect(normalizeKeyToCamelot('12B'), '12B');
        expect(normalizeKeyToCamelot('1A'), '1A');
      });

      test('case insensitive', () {
        expect(normalizeKeyToCamelot('8a'), '8A');
        expect(normalizeKeyToCamelot('12b'), '12B');
      });

      test('whitespace tolerated', () {
        expect(normalizeKeyToCamelot(' 8A '), '8A');
        expect(normalizeKeyToCamelot('8 A'), '8A');
      });

      test('out-of-range numbers reject', () {
        expect(normalizeKeyToCamelot('0A'), isNull);
        expect(normalizeKeyToCamelot('13A'), isNull);
      });
    });

    group('Open Key notation', () {
      test('user-spec examples', () {
        expect(normalizeKeyToCamelot('7m'), '7A');
        expect(normalizeKeyToCamelot('7d'), '7B');
      });

      test('Mixed In Key style — m/d → A/B', () {
        expect(normalizeKeyToCamelot('1m'), '1A');
        expect(normalizeKeyToCamelot('1d'), '1B');
        expect(normalizeKeyToCamelot('12m'), '12A');
        expect(normalizeKeyToCamelot('12d'), '12B');
      });

      test('case insensitive', () {
        expect(normalizeKeyToCamelot('7M'), '7A');
        expect(normalizeKeyToCamelot('7D'), '7B');
      });
    });
  });

  group('camelotSortIndex', () {
    test('orders around the harmonic wheel', () {
      final inputs = [
        '7A', // Dm
        '1A',
        '1B',
        '12B',
        '2A',
        '8B',
      ];
      final sorted = [...inputs]
        ..sort((a, b) => camelotSortIndex(a).compareTo(camelotSortIndex(b)));
      expect(sorted, ['1A', '1B', '2A', '7A', '8B', '12B']);
    });

    test('full wheel order: 1A,1B,2A,2B,...,12A,12B', () {
      final all = <String>[];
      for (var n = 1; n <= 12; n++) {
        all.add('${n}A');
        all.add('${n}B');
      }
      final shuffled = [...all]..shuffle();
      shuffled.sort(
        (a, b) => camelotSortIndex(a).compareTo(camelotSortIndex(b)),
      );
      expect(shuffled, all);
    });

    test('musical notation sorts by harmonic position', () {
      // Dm=7A, D=10B, Am=8A — harmonic order: 7A < 8A < 10B
      final tagged = ['D', 'Am', 'Dm'];
      tagged.sort(
        (a, b) => camelotSortIndex(a).compareTo(camelotSortIndex(b)),
      );
      expect(tagged, ['Dm', 'Am', 'D']);
    });

    test('unknown / null sort to the end', () {
      expect(camelotSortIndex(null), unknownSortIndex);
      expect(camelotSortIndex(''), unknownSortIndex);
      expect(camelotSortIndex('xyz'), unknownSortIndex);
      expect(camelotSortIndex('Cmaj7'), unknownSortIndex);
      expect(unknownSortIndex, greaterThan(camelotSortIndex('12B')));
    });
  });
}
