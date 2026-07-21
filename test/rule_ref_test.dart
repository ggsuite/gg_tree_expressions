// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  group('isRuleKey()', () {
    test('should accept valid rule keys', () {
      expect(isRuleKey('borderWidth'), isTrue);
      expect(isRuleKey('a'), isTrue);
      expect(isRuleKey('a1_b2'), isTrue);
    });

    test('should reject invalid rule keys', () {
      expect(isRuleKey('§borderWidth'), isFalse); // the § prefix is gone
      expect(isRuleKey(''), isFalse);
      expect(isRuleKey('9abc'), isFalse);
      expect(isRuleKey('a b'), isFalse);
      expect(isRuleKey('a.b'), isFalse);
      expect(isRuleKey('a-b'), isFalse);
    });
  });

  group('isReference()', () {
    test('should accept maps with the § key', () {
      expect(isReference({'§': 'borderWidth'}), isTrue);
    });

    test('should reject everything else', () {
      // Strings are never references — resolved values cannot
      // accidentally look unresolved.
      expect(isReference('§borderWidth'), isFalse);
      expect(isReference({'x': '§borderWidth'}), isFalse);
      expect(isReference({'§expression': '1'}), isFalse);
      expect(isReference(null), isFalse);
      expect(isReference(42), isFalse);
      expect(isReference(<Object?>[]), isFalse);
    });
  });

  group('isInlineExpression()', () {
    test('should accept maps with the §expression key', () {
      expect(isInlineExpression({'§expression': '1 + 2'}), isTrue);
      expect(
        isInlineExpression({
          '§expression': 'w',
          '§inputs': {'w': '#w'},
        }),
        isTrue,
      );
    });

    test('should reject everything else', () {
      expect(isInlineExpression({'§': 'x'}), isFalse);
      expect(isInlineExpression('§expression'), isFalse);
      expect(isInlineExpression(null), isFalse);
    });
  });

  group('isMarker()', () {
    test('should accept any map with a §-prefixed key', () {
      expect(isMarker({'§': 'x'}), isTrue);
      expect(isMarker({'§expression': '1'}), isTrue);
      expect(isMarker({'§expresion': '1'}), isTrue); // typo — caught
      expect(isMarker({'a': 1, '§b': 2}), isTrue);
    });

    test('should reject plain values', () {
      expect(isMarker('§borderWidth'), isFalse);
      expect(isMarker('§ 5 Abs. 2'), isFalse);
      expect(isMarker({'a': 1}), isFalse);
      expect(isMarker({1: 'a'}), isFalse);
      expect(isMarker(null), isFalse);
      expect(isMarker(42), isFalse);
      expect(isMarker(<Object?>[]), isFalse);
    });
  });

  group('containsMarker()', () {
    test('should detect markers at any depth', () {
      expect(
        containsMarker({
          'cfg': {
            'sizes': [
              1,
              {'§': 'w'},
            ],
          },
        }),
        isTrue,
      );
      expect(
        containsMarker([
          {'§expression': '1'},
        ]),
        isTrue,
      );
    });

    test('should treat markers as atomic', () {
      // The reference key inside is not scanned separately.
      expect(containsMarker({'§': 'w'}), isTrue);
    });

    test('should reject marker-free values', () {
      expect(containsMarker('§name'), isFalse);
      expect(
        containsMarker({
          'a': ['§name', 1],
        }),
        isFalse,
      );
      expect(containsMarker(<String, dynamic>{}), isFalse);
      expect(containsMarker(<Object?>[]), isFalse);
      expect(containsMarker(null), isFalse);
      expect(containsMarker(42), isFalse);
    });
  });
}
