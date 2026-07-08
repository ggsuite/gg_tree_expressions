// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  group('levenshtein()', () {
    test('should return 0 for equal strings', () {
      expect(levenshtein('same', 'same'), 0);
    });

    test('should return 0 for two empty strings', () {
      expect(levenshtein('', ''), 0);
    });

    test('should return the length of b when a is empty', () {
      expect(levenshtein('', 'abc'), 3);
    });

    test('should return the length of a when b is empty', () {
      expect(levenshtein('abc', ''), 3);
    });

    test('should return 1 for a single substitution', () {
      expect(levenshtein('a', 'b'), 1);
    });

    test('should return 1 for a single insertion', () {
      expect(levenshtein('abc', 'abcd'), 1);
    });

    test('should return 1 for a single deletion', () {
      expect(levenshtein('abcd', 'abc'), 1);
    });

    test('should compute the classic kitten/sitting distance', () {
      expect(levenshtein('kitten', 'sitting'), 3);
    });

    test('should be symmetric', () {
      expect(levenshtein('sitting', 'kitten'), 3);
    });

    test('should swap rows correctly across multiple iterations', () {
      // Requires several outer-loop iterations, exercising the
      // previous/current row swap repeatedly.
      expect(levenshtein('flaw', 'lawn'), 2);
      expect(levenshtein('intention', 'execution'), 5);
    });

    test('should return the full length for disjoint strings', () {
      expect(levenshtein('abc', 'xyz'), 3);
    });
  });

  group('didYouMean()', () {
    test('should return the best match first', () {
      final result = didYouMean('colr', ['colour', 'color']);
      expect(result, ['color', 'colour']);
    });

    test('should place an exact match at the first position', () {
      final result = didYouMean('color', ['colour', 'color']);
      expect(result.first, 'color');
    });

    test('should drop candidates beyond the default maxDistance', () {
      final result = didYouMean('colr', ['color', 'colour', 'columns']);
      expect(result, ['color', 'colour']);
    });

    test('should honor a custom maxDistance', () {
      final result = didYouMean('colr', ['color', 'colour'], maxDistance: 1);
      expect(result, ['color']);
    });

    test('should cap the result at the default maxSuggestions', () {
      final result = didYouMean('aa', ['aa', 'ab', 'ac', 'ad', 'ae']);
      expect(result, hasLength(3));
      expect(result.first, 'aa');
    });

    test('should honor a custom maxSuggestions', () {
      final result = didYouMean('aa', [
        'aa',
        'ab',
        'ac',
        'ad',
      ], maxSuggestions: 2);
      expect(result, hasLength(2));
      expect(result.first, 'aa');
    });

    test('should return an empty list for no candidates', () {
      expect(didYouMean('anything', []), isEmpty);
    });

    test('should return an empty list when nothing is close', () {
      final result = didYouMean('short', ['completelyDifferent']);
      expect(result, isEmpty);
    });
  });
}
