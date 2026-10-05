// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_golden/gg_golden.dart';
import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  group('RuleInput', () {
    group('constructor', () {
      test('should default to hasDefault false and no default value', () {
        final input = RuleInput(query: '#width');
        expect(input.query, '#width');
        expect(input.defaultValue, isNull);
        expect(input.hasDefault, isFalse);
        expect(input.context, isNull);
        expect(input.isContext, isFalse);
      });

      test('should build a context input without a query', () {
        final input = RuleInput(context: 'dimensions/h');
        expect(input.context, 'dimensions/h');
        expect(input.isContext, isTrue);
        expect(input.query, isNull);
        expect(input.hasDefault, isFalse);
      });

      test('should require exactly one of query and context', () {
        expect(() => RuleInput(), throwsA(isA<AssertionError>()));
        expect(
          () => RuleInput(query: '#a', context: 'a'),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    group('fromJson()', () {
      group('short string form', () {
        test('should parse a valid query string', () {
          final input = RuleInput.fromJson(
            '/dialog#width',
            context: 'input "width" of rule "a"',
          );
          expect(input.query, '/dialog#width');
          expect(input.defaultValue, isNull);
          expect(input.hasDefault, isFalse);
        });

        test('should throw on an invalid query naming the context', () {
          var message = '';
          try {
            RuleInput.fromJson('a#b#c', context: 'input "width" of rule "a"');
          } on TreeExpressionsException catch (e) {
            message = e.message;
          }
          expect(
            message,
            contains('Invalid query "a#b#c" in input "width" of rule "a":'),
          );
          expect(message, contains('must only contain one #'));
        });
      });

      group('long map form', () {
        test('should parse query and default', () {
          final input = RuleInput.fromJson({
            'query': '#width',
            'default': 5,
          }, context: 'input "width" of rule "a"');
          expect(input.query, '#width');
          expect(input.defaultValue, 5);
          expect(input.hasDefault, isTrue);
        });

        test('should report hasDefault false without a default key', () {
          final input = RuleInput.fromJson({
            'query': '#width',
          }, context: 'input "width" of rule "a"');
          expect(input.query, '#width');
          expect(input.defaultValue, isNull);
          expect(input.hasDefault, isFalse);
        });

        test('should treat an explicit null default as declared', () {
          final input = RuleInput.fromJson({
            'query': '#width',
            'default': null,
          }, context: 'input "width" of rule "a"');
          expect(input.query, '#width');
          expect(input.defaultValue, isNull);
          expect(input.hasDefault, isTrue);
        });

        test('should throw on unknown keys listing the allowed ones', () {
          var message = '';
          try {
            RuleInput.fromJson({
              'query': '#width',
              'foo': 1,
              'bar': 2,
            }, context: 'input "width" of rule "a"');
          } on TreeExpressionsException catch (e) {
            message = e.message;
          }
          expect(
            message,
            contains(
              'Unknown key(s) "foo", "bar" '
              'in input "width" of rule "a".',
            ),
          );
          expect(message, contains('Allowed keys:'));
          expect(message, contains('  - query'));
          expect(message, contains('  - context'));
          expect(message, contains('  - default'));
        });

        test('should throw on a missing query', () {
          var message = '';
          try {
            RuleInput.fromJson({
              'default': 5,
            }, context: 'input "width" of rule "a"');
          } on TreeExpressionsException catch (e) {
            message = e.message;
          }
          expect(
            message,
            contains(
              'Missing or invalid "query" in '
              'input "width" of rule "a".',
            ),
          );
          expect(message, contains('Expected a tree query string, got: null'));
          expect(message, contains('exactly one of "query"'));
          expect(message, contains('"context"'));
        });

        test('should throw on a non-string query', () {
          var message = '';
          try {
            RuleInput.fromJson({
              'query': 42,
            }, context: 'input "width" of rule "a"');
          } on TreeExpressionsException catch (e) {
            message = e.message;
          }
          expect(message, contains('Expected a tree query string, got: 42'));
        });

        test('should throw on an invalid query string', () {
          var message = '';
          try {
            RuleInput.fromJson({
              'query': 'a#b#c',
            }, context: 'input "width" of rule "a"');
          } on TreeExpressionsException catch (e) {
            message = e.message;
          }
          expect(
            message,
            contains('Invalid query "a#b#c" in input "width" of rule "a":'),
          );
        });

        test('should throw on a non-JSON default value', () {
          var message = '';
          try {
            RuleInput.fromJson({
              'query': '#width',
              'default': DateTime(2026),
            }, context: 'input "width" of rule "a"');
          } on TreeExpressionsException catch (e) {
            message = e.message;
          }
          expect(
            message,
            contains(
              'The default of input "width" of rule "a" '
              'is not a JSON value:',
            ),
          );
          expect(message, contains('(DateTime)'));
        });
      });

      group('context form', () {
        String messageOfFromJson(Object? json) {
          try {
            RuleInput.fromJson(json, context: 'input "h" of rule "a"');
          } on SchemaException catch (e) {
            return e.message;
          }
          return '';
        }

        test('should parse a context path', () {
          final input = RuleInput.fromJson({
            'context': 'dimensions/basicShape/dimensions/h',
          }, context: 'input "h" of rule "a"');
          expect(input.context, 'dimensions/basicShape/dimensions/h');
          expect(input.isContext, isTrue);
          expect(input.query, isNull);
          expect(input.hasDefault, isFalse);
        });

        test('should parse the dotted and indexed path syntax', () {
          for (final path in ['a.b', 'xs[0]', 'a/xs[1][2]/b', '/a']) {
            final input = RuleInput.fromJson({
              'context': path,
            }, context: 'input "h" of rule "a"');
            expect(input.context, path);
          }
        });

        test('should parse a context path with a default', () {
          final input = RuleInput.fromJson({
            'context': 'a/b',
            'default': 5,
          }, context: 'input "h" of rule "a"');
          expect(input.context, 'a/b');
          expect(input.defaultValue, 5);
          expect(input.hasDefault, isTrue);
        });

        test('should treat an explicit null default as declared', () {
          final input = RuleInput.fromJson({
            'context': 'a/b',
            'default': null,
          }, context: 'input "h" of rule "a"');
          expect(input.hasDefault, isTrue);
          expect(input.defaultValue, isNull);
        });

        test('should reject query and context together', () {
          final message = messageOfFromJson({'query': '#a', 'context': 'a'});
          expect(
            message,
            contains('input "h" of rule "a" has both "query" and "context".'),
          );
        });

        test('should reject a non-string context', () {
          for (final bad in [42, null]) {
            final message = messageOfFromJson({'context': bad});
            expect(message, contains('Invalid "context" in input "h"'));
            expect(
              message,
              contains('Expected a context path string, got: $bad'),
            );
          }
        });

        test('should reject an empty context path naming the input', () {
          for (final path in ['', '/', '..']) {
            final message = messageOfFromJson({'context': path});
            expect(
              message,
              contains(
                'Invalid context path "$path" in input "h" of rule "a":',
              ),
            );
            expect(message, contains('the path is empty'));
          }
        });

        test('should reject an invalid context path naming the input', () {
          final message = messageOfFromJson({'context': 'a[x]'});
          expect(
            message,
            contains('Invalid context path "a[x]" in input "h" of rule "a":'),
          );
          expect(message, contains('Invalid path segment "a[x]"'));
        });

        test('should reject a non-JSON default', () {
          final message = messageOfFromJson({
            'context': 'a',
            'default': DateTime(2026),
          });
          expect(
            message,
            contains('The default of input "h" of rule "a" is not a JSON'),
          );
        });
      });

      test('should throw on completely invalid json', () {
        var message = '';
        try {
          RuleInput.fromJson(42, context: 'input "width" of rule "a"');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains('Invalid input definition in input "width" of rule "a": 42'),
        );
        expect(
          message,
          contains(
            'Expected a query string, {"query": …, "default": …} or '
            '{"context": …, "default": …}.',
          ),
        );
      });
    });

    group('toJson()', () {
      test('should serialize to the short form without a default', () {
        final input = RuleInput.fromJson('#width', context: 'input "w"');
        expect(input.toJson(), '#width');

        // Round-trip: the short form parses back to an equal input.
        final reparsed = RuleInput.fromJson(
          input.toJson(),
          context: 'input "w"',
        );
        expect(reparsed.query, input.query);
        expect(reparsed.hasDefault, isFalse);
      });

      test('should serialize to the long form with a default', () {
        final input = RuleInput.fromJson({
          'query': '#width',
          'default': 5,
        }, context: 'input "w"');
        expect(input.toJson(), {'query': '#width', 'default': 5});

        // Round-trip: the long form parses back to an equal input.
        final reparsed = RuleInput.fromJson(
          input.toJson(),
          context: 'input "w"',
        );
        expect(reparsed.query, '#width');
        expect(reparsed.defaultValue, 5);
        expect(reparsed.hasDefault, isTrue);
      });

      test('should keep an explicit null default in the long form', () {
        final input = RuleInput.fromJson({
          'query': '#width',
          'default': null,
        }, context: 'input "w"');
        expect(input.toJson(), {'query': '#width', 'default': null});

        final reparsed = RuleInput.fromJson(
          input.toJson(),
          context: 'input "w"',
        );
        expect(reparsed.hasDefault, isTrue);
        expect(reparsed.defaultValue, isNull);
      });

      test('should serialize a context input to the long form', () {
        final input = RuleInput.fromJson({
          'context': 'a/b',
        }, context: 'input "w"');
        expect(input.toJson(), {'context': 'a/b'});

        final reparsed = RuleInput.fromJson(
          input.toJson(),
          context: 'input "w"',
        );
        expect(reparsed.context, 'a/b');
        expect(reparsed.query, isNull);
        expect(reparsed.hasDefault, isFalse);
      });

      test('should keep the default of a context input', () {
        final input = RuleInput.fromJson({
          'context': 'a/b',
          'default': [1, 2],
        }, context: 'input "w"');
        expect(input.toJson(), {
          'context': 'a/b',
          'default': [1, 2],
        });

        final reparsed = RuleInput.fromJson(
          input.toJson(),
          context: 'input "w"',
        );
        expect(reparsed.context, 'a/b');
        expect(reparsed.defaultValue, [1, 2]);
        expect(reparsed.hasDefault, isTrue);
      });
    });

    group('example()', () {
      test('serializes the example input (golden)', () async {
        final json = RuleInput.example().toJson();
        await writeGolden('rule_input_example.json', json);

        expect(json, {'query': 'screen#width', 'default': 4.0});

        final reparsed = RuleInput.fromJson(json, context: 'example');
        expect(reparsed.query, 'screen#width');
        expect(reparsed.defaultValue, 4.0);
        expect(reparsed.hasDefault, isTrue);
      });
    });
  });
}
