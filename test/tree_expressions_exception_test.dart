// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  group('TreeExpressionsException', () {
    test('should join message lines and print them via toString', () {
      final e = SchemaException(['first line', 'second line']);
      expect(e.messages, ['first line', 'second line']);
      expect(e.message, 'first line\nsecond line');
      expect(e.toString(), e.message);
      expect(e, isA<TreeExpressionsException>());
      expect(e, isA<Exception>());
    });

    test('should expose typed fields per subtype', () {
      expect(
        ExpressionException(['x'], expression: '1 + 2').expression,
        '1 + 2',
      );

      final query = QueryException(['x'], query: '#a', nodePath: '/n');
      expect(query.query, '#a');
      expect(query.nodePath, '/n');

      final unknown = UnknownRuleException(
        ['x'],
        ruleKey: '§a',
        location: '/#x',
        suggestions: ['§ab'],
      );
      expect(unknown.ruleKey, '§a');
      expect(unknown.location, '/#x');
      expect(unknown.suggestions, ['§ab']);

      final circular = CircularAliasException(
        ['x'],
        chain: ['§a', '§b', '§a'],
        location: '/#x',
      );
      expect(circular.chain, ['§a', '§b', '§a']);
      expect(circular.location, '/#x');

      final noVariant = NoVariantException(
        ['x'],
        ruleKey: '§a',
        location: '/#x',
        reasons: ['variant 0: nope'],
      );
      expect(noVariant.ruleKey, '§a');
      expect(noVariant.location, '/#x');
      expect(noVariant.reasons, ['variant 0: nope']);

      final missing = MissingInputException(['x'], inputName: 'w', query: '#w');
      expect(missing.inputName, 'w');
      expect(missing.query, '#w');

      final stuck = StuckException(['x'], pending: ['item a']);
      expect(stuck.pending, ['item a']);

      expect(ResolveException(['x']).messages, ['x']);
    });

    test('should allow exhaustive matching', () {
      String kind(TreeExpressionsException e) => switch (e) {
        SchemaException() => 'schema',
        ExpressionException() => 'expression',
        QueryException() => 'query',
        UnknownRuleException() => 'unknownRule',
        CircularAliasException() => 'circularAlias',
        NoVariantException() => 'noVariant',
        MissingInputException() => 'missingInput',
        StuckException() => 'stuck',
        ResolveException() => 'resolve',
      };
      expect(kind(SchemaException(['x'])), 'schema');
      expect(kind(ResolveException(['x'])), 'resolve');
    });
  });
}
