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

  group('Selector', () {
    group('fromJson()', () {
      test('should return none for null', () {
        final selector = Selector.fromJson(null, context: 'rule "§x"');
        expect(selector, same(Selector.none));
        expect(selector.specificity, 0);
      });

      test('should parse conditions', () {
        final selector = Selector.fromJson({
          'theme#id': 'dark',
          '#width': 380.0,
          './#visible': true,
        }, context: 'rule "§x"');
        expect(selector.specificity, 3);
        expect(selector.conditions['theme#id'], 'dark');
      });

      test('should throw when json is no map', () {
        var message = '';
        try {
          Selector.fromJson('dark', context: 'rule "§x"');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('selector in rule "§x"'));
        expect(message, contains('must be a JSON object'));
      });

      test('should throw on invalid queries', () {
        var message = '';
        try {
          Selector.fromJson({'a#b#c': 1}, context: 'rule "§x"');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Invalid query "a#b#c"'));
        expect(message, contains('the selector of rule "§x"'));
      });

      test('should throw on non-scalar literals', () {
        var message = '';
        try {
          Selector.fromJson({
            '#tags': ['a'],
          }, context: 'rule "§x"');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('invalid literal'));
        expect(message, contains('#tags'));
      });

      test('should throw on null literals with a hint', () {
        var message = '';
        try {
          Selector.fromJson({'#a': null}, context: 'rule "§x"');
        } on TreeExpressionsException catch (e) {
          message = e.message;
        }
        expect(message, contains('Null is not allowed'));
      });
    });

    group('toJson()', () {
      test('should round-trip', () {
        final json = {'theme#id': 'dark', '#w': 2};
        final selector = Selector.fromJson(json, context: 'x');
        expect(selector.toJson(), json);
      });
    });

    group('match()', () {
      test('should succeed on the empty selector', () {
        expect(Selector.none.match(node('me', {})), isA<MatchSuccess>());
      });

      test('should succeed when all conditions hold', () {
        final dialog = node('dialog', {'visible': true});
        node(
          'app',
          {'platform': 'mobile'},
          [
            node('theme', {'id': 'dark'}),
            dialog,
          ],
        );
        final selector = Selector.fromJson({
          'theme#id': 'dark',
          '#platform': 'mobile',
          './#visible': true,
        }, context: 'x');
        expect(selector.match(dialog), isA<MatchSuccess>());
      });

      test('should compare ints and doubles numerically', () {
        final me = node('me', {'w': 2});
        final selector = Selector.fromJson({'./#w': 2.0}, context: 'x');
        expect(selector.match(me), isA<MatchSuccess>());
      });

      test('should fail with reason when a value differs', () {
        final me = node('me', {'w': 3});
        final selector = Selector.fromJson({'./#w': 2}, context: 'x');
        final result = selector.match(me);
        expect(result, isA<MatchFailure>());
        final failure = result as MatchFailure;
        expect(failure.query, './#w');
        expect(failure.expected, 2);
        expect(failure.actual, 3);
        expect(failure.reason, contains('found "3"'));
      });

      test('should fail with reason when a value is missing', () {
        final me = node('me', {});
        final selector = Selector.fromJson({'./#w': 2}, context: 'x');
        final failure = selector.match(me) as MatchFailure;
        expect(failure.actual, isNull);
        expect(failure.reason, contains('no value found'));
      });

      test('should treat shape mismatches as not matching', () {
        final me = node('me', {'num': 5});
        final selector = Selector.fromJson({'./#num/deep': 2}, context: 'x');
        expect(selector.match(me), isA<MatchFailure>());
      });

      test('should block on unresolved values', () {
        final me = node('me', {
          'w': const {'§': '§width'},
        });
        final selector = Selector.fromJson({'./#w': 2}, context: 'x');
        final result = selector.match(me);
        expect(result, isA<MatchBlocked>());
        final blocked = result as MatchBlocked;
        expect(blocked.query, './#w');
        expect(blocked.blocker, '/#w');
      });

      group('with a readCache', () {
        test('should fill the cache on a miss', () {
          final me = node('me', {'w': 2});
          final selector = Selector.fromJson({'./#w': 2}, context: 'x');
          final cache = <String, ReadResult>{};
          expect(selector.match(me, readCache: cache), isA<MatchSuccess>());
          expect(cache['./#w'], isA<ReadValue>());
          expect((cache['./#w']! as ReadValue).value, 2);
        });

        test('should reuse a cached read instead of reading again', () {
          // The node holds w=2, but the cache claims 99. A cache hit
          // makes the "== 99" condition succeed, proving no re-read.
          final me = node('me', {'w': 2});
          final selector = Selector.fromJson({'./#w': 99}, context: 'x');
          final cache = <String, ReadResult>{'./#w': const ReadValue(99)};
          expect(selector.match(me, readCache: cache), isA<MatchSuccess>());
        });
      });
    });
  });
}
