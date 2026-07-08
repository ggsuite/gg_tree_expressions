// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  group('RuleBook', () {
    group('empty()', () {
      test('should create a book without rules', () {
        final book = RuleBook.empty();
        expect(book.keys, isEmpty);
        expect(book.ruleForKey('§borderWidth'), isNull);
      });
    });

    group('fromJson()', () {
      test('should parse rules in shorthand and object form', () {
        final json = <String, dynamic>{
          '§borderWidth': [
            {'expression': '5'},
            {
              'selector': {'#type': 'door'},
              'inputs': {'other': '#otherWidth'},
              'expression': 'other + 5',
            },
          ],
          '§height': {
            'optional': true,
            'resultType': 'number',
            'variants': [
              {'expression': '2.0'},
            ],
          },
        };

        final book = RuleBook.fromJson(json);

        expect(book.keys, ['§borderWidth', '§height']);

        final borderWidth = book.ruleForKey('§borderWidth')!;
        expect(borderWidth.key, '§borderWidth');
        expect(borderWidth.variants, hasLength(2));
        expect(borderWidth.variants[0].expression, '5');
        expect(borderWidth.variants[1].expression, 'other + 5');
        expect(borderWidth.isOptional, isFalse);

        final height = book.ruleForKey('§height')!;
        expect(height.isOptional, isTrue);
        expect(height.resultType, ResultType.number);

        expect(book.ruleForKey('§unknown'), isNull);

        // The book serializes back to the original JSON.
        expect(book.toJson(), json);
      });

      test('should aggregate all invalid rules into one exception', () {
        var message = '';
        var messages = <String>[];
        try {
          RuleBook.fromJson(<String, dynamic>{
            '§valid': [
              {'expression': '1'},
            ],
            'noPrefix': [
              {'expression': '2'},
            ],
            '§empty': <dynamic>[],
          });
        } on TreeExpressionsException catch (e) {
          message = e.message;
          messages = e.messages;
        }

        expect(message, startsWith('Invalid rule book:'));
        expect(message, contains('Invalid rule key "noPrefix".'));
        expect(
          message,
          contains('Rule "§empty" must define a non-empty list of variants.'),
        );

        // The trailing blank line after the last error is removed.
        expect(messages.last, isNot(''));
      });
    });

    group('merge()', () {
      test('should concatenate variants of the same key in order', () {
        final earlier = RuleBook.fromJson(<String, dynamic>{
          '§width': [
            {'expression': '1'},
          ],
        });
        final later = RuleBook.fromJson(<String, dynamic>{
          '§width': [
            {
              'selector': {'#type': 'door'},
              'expression': '2',
            },
          ],
        });

        final merged = RuleBook.merge([earlier, later]);

        final rule = merged.ruleForKey('§width')!;
        expect(rule.variants, hasLength(2));
        expect(rule.variants[0].expression, '1');
        expect(rule.variants[1].expression, '2');
      });

      test('should union disjoint keys', () {
        final a = RuleBook.fromJson(<String, dynamic>{
          '§width': [
            {'expression': '1'},
          ],
        });
        final b = RuleBook.fromJson(<String, dynamic>{
          '§height': [
            {'expression': '2'},
          ],
        });

        final merged = RuleBook.merge([a, b]);

        expect(merged.keys, ['§width', '§height']);
        expect(merged.ruleForKey('§width')!.variants, hasLength(1));
        expect(merged.ruleForKey('§height')!.variants, hasLength(1));
      });

      test('should throw on conflicting optional flags', () {
        final a = RuleBook.fromJson(<String, dynamic>{
          '§width': {
            'optional': true,
            'variants': [
              {'expression': '1'},
            ],
          },
        });
        final b = RuleBook.fromJson(<String, dynamic>{
          '§width': {
            'optional': false,
            'variants': [
              {'expression': '2'},
            ],
          },
        });

        var message = '';
        try {
          RuleBook.merge([a, b]);
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }

        expect(
          message,
          contains('Conflicting "optional" flags for rule "§width"'),
        );
        expect(message, contains('true vs false'));
      });

      test('should throw on conflicting result types', () {
        final a = RuleBook.fromJson(<String, dynamic>{
          '§width': {
            'resultType': 'number',
            'variants': [
              {'expression': '1'},
            ],
          },
        });
        final b = RuleBook.fromJson(<String, dynamic>{
          '§width': {
            'resultType': 'string',
            'variants': [
              {'expression': '2'},
            ],
          },
        });

        var message = '';
        try {
          RuleBook.merge([a, b]);
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }

        expect(message, contains('Conflicting result types for rule "§width"'));
        expect(message, contains('number vs string'));
      });

      test('should return an empty book for zero books', () {
        final merged = RuleBook.merge(<RuleBook>[]);
        expect(merged.keys, isEmpty);
      });

      test('should adopt optional declared only by a later book', () {
        final earlier = RuleBook.fromJson(<String, dynamic>{
          '§width': [
            {'expression': '1'},
          ],
        });
        final later = RuleBook.fromJson(<String, dynamic>{
          '§width': {
            'optional': true,
            'variants': [
              {'expression': '2'},
            ],
          },
        });

        final merged = RuleBook.merge([earlier, later]);

        final rule = merged.ruleForKey('§width')!;
        expect(rule.optionalFlag, isTrue);
        expect(rule.isOptional, isTrue);
        expect(rule.variants, hasLength(2));
      });
    });

    group('suggestionsFor()', () {
      test('should suggest close keys, best match first', () {
        final book = RuleBook.fromJson(<String, dynamic>{
          '§borderWidth': [
            {'expression': '1'},
          ],
          '§borderHeight': [
            {'expression': '2'},
          ],
        });

        expect(book.suggestionsFor('§borderWith'), ['§borderWidth']);
      });

      test('should return no suggestions for distant keys', () {
        final book = RuleBook.fromJson(<String, dynamic>{
          '§borderWidth': [
            {'expression': '1'},
          ],
        });

        expect(book.suggestionsFor('§completelyDifferent'), isEmpty);
      });
    });

    group('lint()', () {
      test('should report identical rules under different names', () {
        final book = RuleBook.fromJson(<String, dynamic>{
          '§a': [
            {'expression': '5'},
          ],
          '§b': [
            {'expression': '5'},
          ],
        });

        final findings = book.lint();

        expect(findings, hasLength(1));
        expect(findings.first, contains('Rules "§a" and "§b" are identical'));
      });

      test('should report identical selectors within one rule', () {
        final book = RuleBook.fromJson(<String, dynamic>{
          '§width': [
            {'expression': '0'},
            {
              'selector': {'#type': 'door'},
              'expression': '1',
            },
            {
              'selector': {'#type': 'door'},
              'expression': '2',
            },
          ],
        });

        final findings = book.lint();

        expect(findings, hasLength(1));
        expect(
          findings.first,
          contains('Rule "§width": variants 1 and 2 have identical selectors'),
        );
        expect(findings.first, contains('variant 2 always wins'));
      });

      test('should report non-optional rules without a base variant', () {
        final book = RuleBook.fromJson(<String, dynamic>{
          '§doorWidth': [
            {
              'selector': {'#type': 'door'},
              'expression': '1',
            },
          ],
        });

        final findings = book.lint();

        expect(findings, hasLength(1));
        expect(
          findings.first,
          contains('Rule "§doorWidth" has no base variant and is not optional'),
        );
      });

      test('should not flag optional rules without a base variant', () {
        final book = RuleBook.fromJson(<String, dynamic>{
          '§doorWidth': {
            'optional': true,
            'variants': [
              {
                'selector': {'#type': 'door'},
                'expression': '1',
              },
            ],
          },
        });

        expect(book.lint(), isEmpty);
      });

      test('should return an empty list for a clean book', () {
        final book = RuleBook.fromJson(<String, dynamic>{
          '§width': [
            {'expression': '1'},
            {
              'selector': {'#type': 'door'},
              'expression': '2',
            },
          ],
          '§height': [
            {'expression': '3'},
            {
              'selector': {'#type': 'drawer'},
              'expression': '4',
            },
          ],
        });

        expect(book.lint(), isEmpty);
      });
    });
  });
}
