// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  group('GgTreeExpressions()', () {
    group('foo()', () {
      test('should return foo', () async {
        const ggTreeExpressions = GgTreeExpressions();
        expect(ggTreeExpressions.foo(), 'foo');
      });
    });
  });
}
