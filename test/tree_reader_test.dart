// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

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

  Json ref() => {'§': 'rule'};

  group('validateQuery()', () {
    test('should accept a parseable query', () {
      validateQuery('#a', context: 'test');
      validateQuery('./x#a/b', context: 'test');
    });

    test('should throw on an invalid query', () {
      var message = '';
      try {
        validateQuery('a#b#c', context: 'selector of rule "x"');
      } on TreeExpressionsException catch (e) {
        message = e.message;
      }
      expect(message, contains('Invalid query "a#b#c"'));
      expect(message, contains('selector of rule "x"'));
    });
  });

  group('messageOf()', () {
    test('should strip the Exception prefix', () {
      expect(messageOf(Exception('boom')), 'boom');
    });

    test('should keep other error texts unchanged', () {
      expect(messageOf(StateError('bad')), 'Bad state: bad');
    });
  });

  group('readQuery()', () {
    group('errors', () {
      test('should throw on an invalid query', () {
        final me = node('me', {});
        var message = '';
        try {
          readQuery(me, 'a#b#c');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Invalid query "a#b#c"'));
        expect(message, contains('at node "/"'));
      });

      test('should wrap shape errors of the underlying read', () {
        final me = node('me', {'num': 5});
        var message = '';
        try {
          readQuery(me, './#num/deep');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Query "./#num/deep" failed'));
        expect(message, contains('at node "/"'));
        expect(message, contains('is not a Map'));
      });

      test('should wrap invalid path segment errors', () {
        final me = node('me', {
          'a': [1],
        });
        var message = '';
        try {
          readQuery(me, './#a[x]');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Query "./#a[x]" failed'));
      });

      test('should wrap index reads into non-lists', () {
        final me = node('me', {'num': 5});
        var message = '';
        try {
          readQuery(me, './#num[0]');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Query "./#num[0]" failed'));
      });
    });

    group('values', () {
      test('should read own-node values', () {
        final me = node('me', {'a': 1});
        final result = readQuery(me, './#a');
        expect(result, isA<ReadValue>());
        expect((result as ReadValue).value, 1);
      });

      test('should read the whole data map with "#"', () {
        final me = node('me', {'a': 1});
        final result = readQuery(me, './#');
        expect((result as ReadValue).value, {'a': 1});
      });

      test('should search upward like getOrNull', () {
        final leaf = node('leaf', {});
        node('root', {'platform': 'mobile'}, [leaf]);
        final result = readQuery(leaf, '#platform');
        expect((result as ReadValue).value, 'mobile');
      });

      test('should read tree info via #node/... without scanning', () {
        // The reference sits right next to the node info — it must
        // not block the read.
        final me = node('me', {'x': ref()});
        final result = readQuery(me, '#node/key');
        expect((result as ReadValue).value, 'me');
      });

      test('should read child node values', () {
        final child = node('child', {'a': 7});
        final me = node('me', {}, [child]);
        final result = readQuery(me, './child#a');
        expect((result as ReadValue).value, 7);
      });

      test('should let clean values shadow markers above', () {
        final leaf = node('leaf', {'w': 5});
        node('root', {'w': ref()}, [leaf]);
        final result = readQuery(leaf, '#w');
        expect((result as ReadValue).value, 5);
      });
    });

    group('missing', () {
      test('should report values found nowhere', () {
        final me = node('me', {});
        expect(readQuery(me, '#nope'), isA<ReadMissing>());
      });

      test('should report out-of-range list indices', () {
        final me = node('me', {
          'items': [1],
        });
        expect(readQuery(me, './#items[5]'), isA<ReadMissing>());
      });

      test('should stop at null items in nested indices', () {
        final me = node('me', {
          'grid': [
            [1],
          ],
        });
        expect(readQuery(me, './#grid[1][0]'), isA<ReadMissing>());
      });
    });

    group('blocked', () {
      test('should block on reference values', () {
        final dialog = node('dialog', {'borderWidth': ref()});
        node('app', {}, [dialog]);
        final result = readQuery(dialog, './#borderWidth');
        expect(result, isA<ReadBlocked>());
        expect((result as ReadBlocked).blocker, '/dialog#borderWidth');
      });

      test('should not block on §-prefixed strings', () {
        final me = node('me', {'text': '§name'});
        final result = readQuery(me, './#text');
        expect((result as ReadValue).value, '§name');
      });

      test('should block on inline expression maps', () {
        final me = node('me', {
          'w': {'§expression': '1.0'},
        });
        expect(readQuery(me, './#w'), isA<ReadBlocked>());
      });

      test('should block on markers deep inside the value', () {
        final me = node('me', {
          'cfg': {
            'nested': [ref()],
          },
        });
        final result = readQuery(me, './#cfg');
        expect((result as ReadBlocked).blocker, '/#cfg');
      });

      test('should block on markers found via upward search', () {
        final leaf = node('leaf', {});
        node('root', {'w': ref()}, [leaf]);
        final result = readQuery(leaf, '#w');
        expect((result as ReadBlocked).blocker, '/#w');
      });

      test('should block instead of searching past an inline map', () {
        // The nearest 'cfg' is still an unresolved inline expression.
        // Searching past it to the root's cfg/depth would resolve
        // against the wrong context — the read must wait.
        final leaf = node('leaf', {
          'cfg': {'§expression': '1.0'},
        });
        node(
          'root',
          {
            'cfg': {'depth': 600},
          },
          [leaf],
        );
        final result = readQuery(leaf, '#cfg/depth');
        expect(result, isA<ReadBlocked>());
        expect((result as ReadBlocked).blocker, '/leaf#cfg');
      });

      test('should block on markers on the data path', () {
        final me = node('me', {'cfg': ref()});
        final result = readQuery(me, './#cfg/depth');
        expect((result as ReadBlocked).blocker, '/#cfg');
      });

      test('should block on marker list items on the path', () {
        final me = node('me', {
          'items': [ref()],
        });
        final result = readQuery(me, './#items[0]');
        expect((result as ReadBlocked).blocker, '/#items[0]');
      });

      test('should block on markers hit between two indices', () {
        final me = node('me', {
          'pairs': [ref()],
        });
        final result = readQuery(me, './#pairs[0][1]');
        expect((result as ReadBlocked).blocker, '/#pairs[0]');
      });
    });

    group('parsed-query cache', () {
      test('should reuse, bound, and survive a clear', () {
        final me = node('me', {'a': 1});
        // Miss then hit for the same query.
        expect(readQuery(me, '#a'), isA<ReadValue>());
        expect(readQuery(me, '#a'), isA<ReadValue>());
        // > 512 distinct queries force the bounded clear at least once.
        for (var i = 0; i < 600; i++) {
          expect(readQuery(me, '#k$i'), isA<ReadMissing>());
        }
        // Reads still work after the cache was cleared.
        expect(readQuery(me, '#a'), isA<ReadValue>());
      });
    });
  });
}
