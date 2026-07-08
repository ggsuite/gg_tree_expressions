// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

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
          contains('Expected a query string or {"query": …, "default": …}.'),
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
    });
  });
}
