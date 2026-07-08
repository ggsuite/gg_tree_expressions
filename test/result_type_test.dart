// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  group('ResultType', () {
    group('fromJson()', () {
      test('should parse "number"', () {
        expect(
          ResultType.fromJson('number', context: 'rule "a"'),
          ResultType.number,
        );
      });

      test('should parse "string"', () {
        expect(
          ResultType.fromJson('string', context: 'rule "a"'),
          ResultType.string,
        );
      });

      test('should parse "bool"', () {
        expect(
          ResultType.fromJson('bool', context: 'rule "a"'),
          ResultType.boolean,
        );
      });

      test('should parse "list"', () {
        expect(
          ResultType.fromJson('list', context: 'rule "a"'),
          ResultType.list,
        );
      });

      test('should parse "map"', () {
        expect(ResultType.fromJson('map', context: 'rule "a"'), ResultType.map);
      });

      test('should throw on unknown values listing the allowed ones', () {
        var message = '';
        try {
          ResultType.fromJson('float', context: 'rule "a"');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Invalid resultType "float" in rule "a".'));
        expect(message, contains('Allowed values:'));
        expect(message, contains('  - number'));
        expect(message, contains('  - string'));
        expect(message, contains('  - bool'));
        expect(message, contains('  - list'));
        expect(message, contains('  - map'));
      });

      test('should throw on non-string values', () {
        var message = '';
        try {
          ResultType.fromJson(42, context: 'rule "b"');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Invalid resultType "42" in rule "b".'));
      });
    });

    group('accepts()', () {
      test('should accept int and double for number', () {
        expect(ResultType.number.accepts(1), isTrue);
        expect(ResultType.number.accepts(1.5), isTrue);
        expect(ResultType.number.accepts('1'), isFalse);
        expect(ResultType.number.accepts(null), isFalse);
      });

      test('should accept only strings for string', () {
        expect(ResultType.string.accepts('hello'), isTrue);
        expect(ResultType.string.accepts(1), isFalse);
      });

      test('should accept only bools for boolean', () {
        expect(ResultType.boolean.accepts(true), isTrue);
        expect(ResultType.boolean.accepts(false), isTrue);
        expect(ResultType.boolean.accepts('true'), isFalse);
      });

      test('should accept only lists for list', () {
        expect(ResultType.list.accepts(<int>[1, 2]), isTrue);
        expect(ResultType.list.accepts(<String, int>{}), isFalse);
      });

      test('should accept only maps for map', () {
        expect(ResultType.map.accepts(<String, int>{'a': 1}), isTrue);
        expect(ResultType.map.accepts(<int>[]), isFalse);
      });
    });

    group('jsonValue', () {
      test('should expose the JSON representation of each type', () {
        expect(ResultType.number.jsonValue, 'number');
        expect(ResultType.string.jsonValue, 'string');
        expect(ResultType.boolean.jsonValue, 'bool');
        expect(ResultType.list.jsonValue, 'list');
        expect(ResultType.map.jsonValue, 'map');
      });
    });
  });
}
