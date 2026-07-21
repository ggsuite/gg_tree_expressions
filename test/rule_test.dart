// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_golden/gg_golden.dart';
import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';
import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  Tree<Json> node(
    String key,
    Json data, [
    List<Tree<Json>> children = const [],
  ]) => Tree<Json>(key: key, data: data, children: children);

  String messageOfCall(void Function() call) {
    try {
      call();
    } on TreeExpressionsException catch (e) {
      return e.message;
    }
    return '';
  }

  group('Rule', () {
    group('fromJson()', () {
      test('should parse the list shorthand', () {
        final rule = Rule.fromJson('w', [
          {'expression': '1.0'},
        ]);
        expect(rule.key, 'w');
        expect(rule.variants.length, 1);
        expect(rule.optionalFlag, isNull);
        expect(rule.isOptional, isFalse);
        expect(rule.resultType, isNull);
      });

      test('should parse the object form', () {
        final rule = Rule.fromJson('w', {
          'optional': true,
          'resultType': 'number',
          'variants': [
            {'expression': '1.0'},
          ],
        });
        expect(rule.optionalFlag, isTrue);
        expect(rule.isOptional, isTrue);
        expect(rule.resultType, ResultType.number);
      });

      test('should throw on invalid rule keys', () {
        final message = messageOfCall(() => Rule.fromJson('9bad', []));
        expect(message, contains('Invalid rule key "9bad"'));
        expect(message, contains('a letter followed by'));
      });

      test('should throw on unknown keys in the object form', () {
        final message = messageOfCall(
          () => Rule.fromJson('w', {'variants': <Object?>[], 'optionl': true}),
        );
        expect(message, contains('Unknown key(s) "optionl"'));
        expect(message, contains('  - optional'));
      });

      test('should throw on non-bool optional flags', () {
        final message = messageOfCall(
          () => Rule.fromJson('w', {
            'optional': 'yes',
            'variants': [
              {'expression': '1.0'},
            ],
          }),
        );
        expect(message, contains('"optional" flag of rule "w"'));
      });

      test('should throw on invalid result types', () {
        final message = messageOfCall(
          () => Rule.fromJson('w', {
            'resultType': 'float',
            'variants': [
              {'expression': '1.0'},
            ],
          }),
        );
        expect(message, contains('Invalid resultType "float"'));
        expect(message, contains('rule "w"'));
      });

      test('should throw when variants are no list', () {
        final message = messageOfCall(
          () => Rule.fromJson('w', {'expression': '1.0'}),
        );
        expect(message, contains('non-empty list of variants'));
      });

      test('should throw when variants are empty', () {
        final message = messageOfCall(() => Rule.fromJson('w', <Object?>[]));
        expect(message, contains('non-empty list of variants'));
      });
    });

    group('select()', () {
      final json = [
        {'expression': '1.0'},
        {
          'selector': {'theme#id': 'dark'},
          'expression': '2.0',
        },
        {
          'selector': {'theme#id': 'dark', '#platform': 'mobile'},
          'expression': '3.0',
        },
      ];

      test('should pick the base variant when nothing else matches', () {
        final rule = Rule.fromJson('w', json);
        final me = node('me', {});
        final result = rule.select(me) as SelectMatch;
        expect(result.index, 0);
        expect(result.variant.expression, '1.0');
      });

      test('should pick the most specific matching variant', () {
        final rule = Rule.fromJson('w', json);
        final me = node(
          'me',
          {'platform': 'mobile'},
          [
            node('theme', {'id': 'dark'}),
          ],
        );
        final result = rule.select(me) as SelectMatch;
        expect(result.index, 2);
        expect(result.variant.expression, '3.0');
      });

      test('should report ambiguity when two base variants tie', () {
        final rule = Rule.fromJson('w', [
          {'expression': '1.0'},
          {'expression': '2.0'},
        ]);
        final result = rule.select(node('me', {}));
        expect(result, isA<SelectAmbiguous>());
        final ambiguous = result as SelectAmbiguous;
        expect(ambiguous.specificity, 0);
        expect(ambiguous.matches.map((m) => m.index), [0, 1]);
      });

      test('should report ambiguity when two selectors tie at the top', () {
        final rule = Rule.fromJson('w', [
          {'expression': '0.0'},
          {
            'selector': {'#a': 1},
            'expression': '1.0',
          },
          {
            'selector': {'#b': 2},
            'expression': '2.0',
          },
        ]);
        final result = rule.select(node('me', {'a': 1, 'b': 2}));
        expect(result, isA<SelectAmbiguous>());
        final ambiguous = result as SelectAmbiguous;
        // The base variant (specificity 0) is outranked; only the two
        // specificity-1 matches tie.
        expect(ambiguous.specificity, 1);
        expect(ambiguous.matches.map((m) => m.index), [1, 2]);
      });

      test('should report reasons when no variant matches', () {
        final rule = Rule.fromJson('w', [
          {
            'selector': {'#platform': 'mobile'},
            'expression': '1.0',
          },
          {
            'selector': {'#platform': 'desktop'},
            'expression': '2.0',
          },
        ]);
        final result = rule.select(node('me', {'platform': 'tv'}));
        expect(result, isA<SelectNone>());
        final none = result as SelectNone;
        expect(none.reasons, hasLength(2));
        expect(none.reasons[0], startsWith('variant 0:'));
        expect(none.reasons[1], contains('found "tv"'));
      });

      test('should block when a blocked variant could win', () {
        final rule = Rule.fromJson('w', json);
        final me = node('me', {}, [
          node('theme', {
            'id': const {'§': 'themeId'},
          }),
        ]);
        final result = rule.select(me);
        expect(result, isA<SelectBlocked>());
        final blocked = result as SelectBlocked;
        expect(blocked.query, 'theme#id');
        expect(blocked.blocker, '/theme#id');
      });

      test('should ignore blocked variants that cannot win', () {
        final rule = Rule.fromJson('w', [
          {
            'selector': {'#unresolved': 1},
            'expression': '1.0',
          },
          {
            'selector': {'#a': 1, '#b': 2},
            'expression': '2.0',
          },
        ]);
        final me = node('me', {
          'unresolved': const {'§': 'x'},
          'a': 1,
          'b': 2,
        });
        final result = rule.select(me) as SelectMatch;
        expect(result.index, 1);
      });

      test('should block on ties when the blocked variant is later', () {
        final rule = Rule.fromJson('w', [
          {
            'selector': {'#a': 1},
            'expression': '1.0',
          },
          {
            'selector': {'#unresolved': 1},
            'expression': '2.0',
          },
        ]);
        final me = node('me', {
          'unresolved': const {'§': 'x'},
          'a': 1,
        });
        expect(rule.select(me), isA<SelectBlocked>());
      });

      test('should block when an earlier blocked variant could tie', () {
        // The blocked variant (index 0) has the same specificity as the
        // matching variant (index 1); once resolved it might match and
        // create a tie, so selection must defer rather than pick one.
        final rule = Rule.fromJson('w', [
          {
            'selector': {'#unresolved': 1},
            'expression': '1.0',
          },
          {
            'selector': {'#a': 1},
            'expression': '2.0',
          },
        ]);
        final me = node('me', {
          'unresolved': const {'§': 'x'},
          'a': 1,
        });
        expect(rule.select(me), isA<SelectBlocked>());
      });

      test('should keep the strongest blocked variant', () {
        final rule = Rule.fromJson('w', [
          {
            'selector': {'#u1': 1, '#u2': 2},
            'expression': '1.0',
          },
          {
            'selector': {'#u1': 1},
            'expression': '2.0',
          },
        ]);
        final me = node('me', {
          'u1': const {'§': 'x'},
          'u2': const {'§': 'y'},
        });
        final blocked = rule.select(me) as SelectBlocked;
        expect(blocked.query, '#u1');
      });

      // ---- when predicates (stubbed evaluator; CEL is exercised in
      // resolver_test) ----

      WhenEvaluator whenIs(Map<String, MatchResult> byPredicate) =>
          (variant, node, index) =>
              byPredicate[variant.when] ??
              const MatchFailure.reason('no stub for this predicate');

      test('a when-variant outranks the base when its predicate holds', () {
        final rule = Rule.fromJson('w', [
          {'expression': '0'},
          {'when': 'tall', 'expression': '1'},
        ]);
        final result = rule.select(
          node('me', {}),
          evaluateWhen: whenIs({'tall': const MatchSuccess()}),
        );
        expect((result as SelectMatch).index, 1);
      });

      test('falls back to the base when the when predicate is false', () {
        final rule = Rule.fromJson('w', [
          {'expression': '0'},
          {'when': 'tall', 'expression': '1'},
        ]);
        final result = rule.select(
          node('me', {}),
          evaluateWhen: whenIs({'tall': const MatchFailure.reason('nope')}),
        );
        expect((result as SelectMatch).index, 0);
      });

      test('defers when the when predicate is blocked', () {
        final rule = Rule.fromJson('w', [
          {'when': 'tall', 'expression': '1'},
        ]);
        final result = rule.select(
          node('me', {}),
          evaluateWhen: whenIs({'tall': const MatchBlocked('#h', '/#h')}),
        );
        expect(result, isA<SelectBlocked>());
      });

      test('more selector conditions outrank a when tiebreaker', () {
        final rule = Rule.fromJson('w', [
          {
            'selector': {'#a': 1, '#b': 2},
            'expression': 'AB',
          },
          {
            'selector': {'#a': 1},
            'when': 'P',
            'expression': 'Awhen',
          },
        ]);
        final result = rule.select(
          node('me', {'a': 1, 'b': 2}),
          evaluateWhen: whenIs({'P': const MatchSuccess()}),
        );
        expect((result as SelectMatch).index, 0);
      });

      test("does not evaluate a dominated variant's when", () {
        // Variant 0 (2 conditions) strictly outranks variant 1 (1
        // condition + when). Variant 1's when must never run — a
        // throwing evaluator proves it is skipped.
        final rule = Rule.fromJson('w', [
          {
            'selector': {'#a': 1, '#b': 2},
            'expression': 'AB',
          },
          {
            'selector': {'#a': 1},
            'when': 'P',
            'expression': 'Awhen',
          },
        ]);
        final result = rule.select(
          node('me', {'a': 1, 'b': 2}),
          evaluateWhen: (v, n, i) =>
              throw StateError('dominated when must not be evaluated'),
        );
        expect((result as SelectMatch).index, 0);
      });

      test('two when-variants that both hold at one tier are ambiguous', () {
        final rule = Rule.fromJson('w', [
          {'when': 'short', 'expression': '1'},
          {'when': 'wide', 'expression': '2'},
        ]);
        final result = rule.select(
          node('me', {}),
          evaluateWhen: whenIs({
            'short': const MatchSuccess(),
            'wide': const MatchSuccess(),
          }),
        );
        expect(result, isA<SelectAmbiguous>());
        expect((result as SelectAmbiguous).matches.map((m) => m.index), [0, 1]);
      });

      test('does not evaluate when when the selector already fails', () {
        var whenCalls = 0;
        final rule = Rule.fromJson('w', [
          {
            'selector': {'#a': 1},
            'when': 'P',
            'expression': '1',
          },
          {'expression': '0'},
        ]);
        final result = rule.select(
          node('me', {'a': 2}),
          evaluateWhen: (v, n, i) {
            whenCalls++;
            return const MatchSuccess();
          },
        );
        expect((result as SelectMatch).index, 1);
        expect(whenCalls, 0);
      });

      test('throws when a when-variant is selected without an evaluator', () {
        final rule = Rule.fromJson('w', [
          {'when': 'P', 'expression': '1'},
        ]);
        expect(() => rule.select(node('me', {})), throwsStateError);
      });
    });

    group('merged()', () {
      test('should concatenate variants', () {
        final a = Rule.fromJson('w', [
          {'expression': '1.0'},
        ]);
        final b = Rule.fromJson('w', [
          {'expression': '2.0'},
        ]);
        final merged = a.merged(b);
        expect(merged.variants.map((v) => v.expression), ['1.0', '2.0']);
      });

      test('should throw on different keys', () {
        final a = Rule.fromJson('a', [
          {'expression': '1.0'},
        ]);
        final b = Rule.fromJson('b', [
          {'expression': '2.0'},
        ]);
        final message = messageOfCall(() => a.merged(b));
        expect(message, contains('Cannot merge rule "b" into rule "a"'));
      });

      test('should inherit flags from either side', () {
        final a = Rule.fromJson('w', {
          'optional': true,
          'resultType': 'number',
          'variants': [
            {'expression': '1.0'},
          ],
        });
        final b = Rule.fromJson('w', [
          {'expression': '2.0'},
        ]);
        final merged = a.merged(b);
        expect(merged.optionalFlag, isTrue);
        expect(merged.resultType, ResultType.number);

        final reversed = b.merged(a);
        expect(reversed.optionalFlag, isTrue);
        expect(reversed.resultType, ResultType.number);
      });

      test('should throw on conflicting optional flags', () {
        final a = Rule.fromJson('w', {
          'optional': true,
          'variants': [
            {'expression': '1.0'},
          ],
        });
        final b = Rule.fromJson('w', {
          'optional': false,
          'variants': [
            {'expression': '2.0'},
          ],
        });
        final message = messageOfCall(() => a.merged(b));
        expect(message, contains('Conflicting "optional" flags'));
      });

      test('should throw on conflicting result types', () {
        final a = Rule.fromJson('w', {
          'resultType': 'number',
          'variants': [
            {'expression': '1.0'},
          ],
        });
        final b = Rule.fromJson('w', {
          'resultType': 'string',
          'variants': [
            {'expression': '2.0'},
          ],
        });
        final message = messageOfCall(() => a.merged(b));
        expect(message, contains('Conflicting result types'));
        expect(message, contains('number vs string'));
      });
    });

    group('toJson()', () {
      test('should use the shorthand without rule-level fields', () {
        final json = [
          {'expression': '1.0'},
        ];
        final rule = Rule.fromJson('w', json);
        expect(rule.toJson(), json);
      });

      test('should use the object form with rule-level fields', () {
        final json = {
          'optional': true,
          'resultType': 'bool',
          'variants': [
            {'expression': 'true'},
          ],
        };
        final rule = Rule.fromJson('w', json);
        expect(rule.toJson(), json);
      });
    });

    group('example()', () {
      test('serializes the example rule (golden)', () async {
        final json = Rule.example().toJson();
        await writeGolden('rule_example.json', json);

        expect(Rule.example().key, 'borderWidth');

        final reparsed = Rule.fromJson('borderWidth', json);
        expect(reparsed.toJson(), json);
        expect(reparsed.variants, hasLength(3));
        expect(reparsed.resultType, ResultType.number);
      });
    });
  });
}
