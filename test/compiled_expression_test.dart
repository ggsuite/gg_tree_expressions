// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  final fixtures =
      jsonDecode(File('test/fixtures/cel_conformance.json').readAsStringSync())
          as Map<String, dynamic>;

  Object? run(String expression, Json inputs) =>
      CompiledExpression.compile(expression).evaluate(inputs);

  group('CompiledExpression', () {
    group('conformance fixtures', () {
      for (final section in ['evaluate', 'quirks']) {
        group(section, () {
          for (final Json vector in (fixtures[section] as List).cast()) {
            final expression = vector['expression'] as String;
            final inputs = (vector['inputs'] ?? <String, dynamic>{}) as Json;
            test('should evaluate "$expression"', () {
              expect(run(expression, inputs), vector['expected']);
            });
          }
        });
      }

      group('evaluateErrors', () {
        for (final Json vector in (fixtures['evaluateErrors'] as List).cast()) {
          final expression = vector['expression'] as String;
          final inputs = (vector['inputs'] ?? <String, dynamic>{}) as Json;
          final errorContains = vector['errorContains'] as String;
          test('should fail evaluating "$expression"', () {
            var message = '';
            try {
              run(expression, inputs);
            } on TreeExpressionsException catch (e) {
              message = e.message;
            }
            expect(message, contains(errorContains));
          });
        }
      });

      group('compileErrors', () {
        for (final Json vector in (fixtures['compileErrors'] as List).cast()) {
          final expression = vector['expression'] as String;
          final errorContains = vector['errorContains'] as String;
          test('should fail compiling "$expression"', () {
            var message = '';
            try {
              CompiledExpression.compile(expression);
            } on TreeExpressionsException catch (e) {
              message = e.message;
            }
            expect(message, contains(errorContains));
          });
        }
      });
    });

    group('compile()', () {
      test('should reuse cached instances per source', () {
        final cache = <String, CompiledExpression>{};
        final a = CompiledExpression.compile('1 + 2', cache: cache);
        final b = CompiledExpression.compile('1 + 2', cache: cache);
        final c = CompiledExpression.compile('1 + 3', cache: cache);
        expect(identical(a, b), isTrue);
        expect(identical(a, c), isFalse);
        expect(cache.keys, ['1 + 2', '1 + 3']);
      });

      test('should expose the source', () {
        expect(CompiledExpression.compile('1 + 2').source, '1 + 2');
      });
    });

    group('evaluate()', () {
      test('should evaluate the same program with changing inputs', () {
        final expression = CompiledExpression.compile('a + b');
        expect(expression.evaluate({'a': 1, 'b': 2}), 3);
        expect(expression.evaluate({'a': 10, 'b': 20}), 30);
      });

      test('should return infinity for double division by zero', () {
        expect(run('1.0 / 0.0', {}), double.infinity);
      });

      test('should convert map results to string-keyed json', () {
        final result = run('{\'a\': {\'b\': [1, 2]}}', {});
        expect(result, {
          'a': {
            'b': [1, 2],
          },
        });
        expect(result, isA<Map<String, dynamic>>());
      });

      test('should reject map results with non-string keys', () {
        var message = '';
        try {
          run('{1: \'a\'}', {});
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('non-string'));
        expect(message, contains('key 1 (int)'));
      });

      test('should report unsupported binding values clearly', () {
        final expression = CompiledExpression.compile('x == null');
        var message = '';
        try {
          expression.evaluate({'x': DateTime(2026)});
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Evaluation of expression'));
        expect(message, contains('Unsupported type'));
      });

      test('should name missing variables without inputs', () {
        var message = '';
        try {
          run('missing', {});
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Unknown variable "missing"'));
        expect(message, contains('Available inputs: (none)'));
      });

      test('should keep leading-dot identifiers concise', () {
        var message = '';
        try {
          run('.foo', {'a': 1});
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Unknown variable ".foo"'));
        expect(message, isNot(contains('EvalActivation')));
      });

      test('should report failed member access distinctly', () {
        var message = '';
        try {
          run('m.a.b', {
            'm': {'a': 5},
          });
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Failed to read a member of input "m"'));
        expect(message, isNot(contains('Unknown variable')));
      });

      test('should bind deeply nested structures', () {
        final result = run('cfg.rows[0]["cells"][1]', {
          'cfg': {
            'rows': [
              {
                'cells': ['a', 'b'],
              },
            ],
          },
        });
        expect(result, 'b');
      });

      test('should bind maps nested inside lists', () {
        final result = run('rows[0]', {
          'rows': [
            {'w': 1},
          ],
        });
        expect(result, {'w': 1});
      });
    });
  });
}
