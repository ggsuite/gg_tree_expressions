// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  group('celReservedWords', () {
    test('should contain the CEL reserved identifiers', () {
      expect(celReservedWords, contains('in'));
      expect(celReservedWords, contains('true'));
      expect(celReservedWords, contains('null'));
      expect(celReservedWords, contains('while'));
      expect(celReservedWords.contains('width'), isFalse);
    });
  });

  group('RuleVariant', () {
    group('constructor', () {
      test('should default selector to Selector.none', () {
        final variant = RuleVariant(expression: 'a + b');
        expect(variant.selector, same(Selector.none));
        expect(variant.selector.conditions, isEmpty);
      });

      test('should default inputs to an empty map', () {
        final variant = RuleVariant(expression: 'a + b');
        expect(variant.inputs, const <String, RuleInput>{});
        expect(variant.description, isNull);
        expect(variant.expression, 'a + b');
      });
    });

    group('fromJson()', () {
      test('should parse a variant with only an expression', () {
        final variant = RuleVariant.fromJson({
          'expression': '1 + 2',
        }, context: 'test variant');

        expect(variant.expression, '1 + 2');
        expect(variant.selector, same(Selector.none));
        expect(variant.inputs, isEmpty);
        expect(variant.description, isNull);
      });

      test('should parse a variant with a selector', () {
        final variant = RuleVariant.fromJson({
          'expression': '10',
          'selector': {'#type': 'door'},
        }, context: 'test variant');

        expect(variant.selector.conditions, {'#type': 'door'});
        expect(variant.selector.specificity, 1);
      });

      test('should parse short form inputs', () {
        final variant = RuleVariant.fromJson({
          'expression': 'width * 2',
          'inputs': {'width': '#width'},
        }, context: 'test variant');

        final input = variant.inputs['width']!;
        expect(input.query, '#width');
        expect(input.hasDefault, isFalse);
        expect(input.defaultValue, isNull);
      });

      test('should parse long form inputs', () {
        final variant = RuleVariant.fromJson({
          'expression': 'height + 1',
          'inputs': {
            'height': {'query': '#height', 'default': 42},
          },
        }, context: 'test variant');

        final input = variant.inputs['height']!;
        expect(input.query, '#height');
        expect(input.hasDefault, isTrue);
        expect(input.defaultValue, 42);
      });

      test('should parse a variant with a description', () {
        final variant = RuleVariant.fromJson({
          'expression': '5',
          'description': 'Computes five.',
        }, context: 'test variant');

        expect(variant.description, 'Computes five.');
      });

      test('should throw when json is not a map', () {
        var message = '';
        try {
          RuleVariant.fromJson('nope', context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains('test variant must be a JSON object, got: nope'),
        );
      });

      test('should throw on unknown keys listing the allowed keys', () {
        var message = '';
        try {
          RuleVariant.fromJson({
            'expression': '1',
            'foo': 1,
            'bar': 2,
          }, context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains('Unknown key(s) "foo", "bar" in test variant.'),
        );
        expect(message, contains('Allowed keys:'));
        expect(message, contains('  - selector'));
        expect(message, contains('  - inputs'));
        expect(message, contains('  - expression'));
        expect(message, contains('  - description'));
      });

      test('should throw when the expression is missing', () {
        var message = '';
        try {
          RuleVariant.fromJson(<String, Object?>{}, context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains('Missing or empty "expression" in test variant.'),
        );
        expect(
          message,
          contains('Every variant needs a CEL expression string.'),
        );
      });

      test('should throw when the expression is empty', () {
        var message = '';
        try {
          RuleVariant.fromJson({'expression': ''}, context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains('Missing or empty "expression" in test variant.'),
        );
      });

      test('should throw when the expression is whitespace only', () {
        var message = '';
        try {
          RuleVariant.fromJson({'expression': '   '}, context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains('Missing or empty "expression" in test variant.'),
        );
      });

      test('should throw when the expression is not a string', () {
        var message = '';
        try {
          RuleVariant.fromJson({'expression': 42}, context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains('Missing or empty "expression" in test variant.'),
        );
      });

      test('should throw when the description is not a string', () {
        var message = '';
        try {
          RuleVariant.fromJson({
            'expression': '1',
            'description': 5,
          }, context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains(
            'The "description" of test variant must be a string, got: 5',
          ),
        );
      });

      test('should throw when inputs is not a map', () {
        var message = '';
        try {
          RuleVariant.fromJson({
            'expression': '1',
            'inputs': 'nope',
          }, context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains(
            'The "inputs" of test variant must be a JSON object '
            'mapping CEL identifiers to tree queries.',
          ),
        );
        expect(message, contains('Got: nope'));
      });

      test('should throw on an input name starting with a digit', () {
        var message = '';
        try {
          RuleVariant.fromJson({
            'expression': '1',
            'inputs': {'1abc': '#a'},
          }, context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains(
            '"1abc" is not a valid CEL identifier (input of test variant).',
          ),
        );
        expect(
          message,
          contains(
            'Identifiers match [a-zA-Z_][a-zA-Z0-9_]* and must not be '
            'a CEL reserved word.',
          ),
        );
      });

      test('should throw on an input name containing a dash', () {
        var message = '';
        try {
          RuleVariant.fromJson({
            'expression': '1',
            'inputs': {'a-b': '#a'},
          }, context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains(
            '"a-b" is not a valid CEL identifier (input of test variant).',
          ),
        );
      });

      test('should throw on the reserved word "in" as input name', () {
        var message = '';
        try {
          RuleVariant.fromJson({
            'expression': '1',
            'inputs': {'in': '#a'},
          }, context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains(
            '"in" is not a valid CEL identifier (input of test variant).',
          ),
        );
      });

      test('should throw on the reserved word "true" as input name', () {
        var message = '';
        try {
          RuleVariant.fromJson({
            'expression': '1',
            'inputs': {'true': '#a'},
          }, context: 'test variant');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(
          message,
          contains(
            '"true" is not a valid CEL identifier (input of test variant).',
          ),
        );
      });
    });

    group('toJson()', () {
      test('should emit only the expression for a minimal variant', () {
        final json = RuleVariant(expression: 'x').toJson();
        expect(json, {'expression': 'x'});
      });

      test('should emit selector, inputs, expression and description', () {
        final variant = RuleVariant.fromJson({
          'expression': 'width * height',
          'selector': {'#type': 'door'},
          'inputs': {
            'width': '#width',
            'height': {'query': '#height', 'default': 42},
          },
          'description': 'Area of a door.',
        }, context: 'test variant');

        expect(variant.toJson(), {
          'selector': {'#type': 'door'},
          'inputs': {
            'width': '#width',
            'height': {'query': '#height', 'default': 42},
          },
          'expression': 'width * height',
          'description': 'Area of a door.',
        });
      });

      test('should round-trip through fromJson', () {
        final original = RuleVariant.fromJson({
          'expression': 'width + 1',
          'selector': {'#kind': 'shelf', '#count': 3},
          'inputs': {
            'width': '#width',
            'depth': {'query': '#depth', 'default': null},
          },
          'description': 'Round trip.',
        }, context: 'test variant');

        final copy = RuleVariant.fromJson(
          original.toJson(),
          context: 'round trip',
        );

        expect(copy.toJson(), original.toJson());
        expect(copy.expression, original.expression);
        expect(copy.selector.conditions, original.selector.conditions);
        expect(copy.description, original.description);
        expect(copy.inputs.keys, original.inputs.keys);
        expect(copy.inputs['depth']!.hasDefault, isTrue);
        expect(copy.inputs['depth']!.defaultValue, isNull);
      });
    });
  });
}
