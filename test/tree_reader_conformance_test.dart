// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Property-style conformance harness: readQuery mirrors gg_tree's
// private search semantics, so this test pins the two against each
// other over a generated corpus. If a gg_tree upgrade changes the
// search behavior, this fails before the resolver silently diverges.

import 'dart:math';

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';
import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  final random = Random(20260707);

  const dataKeys = ['a', 'b', 'cfg', 'w'];
  const nodeKeys = ['child0', 'child1', 'sub'];

  Object? randomValue(int depth) {
    final roll = random.nextInt(10);
    if (depth < 2 && roll == 0) {
      return {
        for (final key in dataKeys)
          if (random.nextBool()) key: randomValue(depth + 1),
      };
    }
    if (depth < 2 && roll == 1) {
      return [
        for (var i = 0; i < random.nextInt(3); i++) randomValue(depth + 1),
      ];
    }
    return switch (roll % 6) {
      0 => {'§': '§rule'},
      1 => {'§expression': '1.0'},
      2 => random.nextInt(100),
      3 => 'text${random.nextInt(3)}',
      4 => random.nextBool(),
      _ => null,
    };
  }

  Json randomData() => {
    for (final key in dataKeys)
      if (random.nextBool()) key: randomValue(0),
  };

  Tree<Json> randomTree(int depth) => Tree<Json>(
    key: depth == 0 ? 'root' : nodeKeys[random.nextInt(nodeKeys.length)],
    data: randomData(),
    children: [
      if (depth < 2)
        for (var i = 0; i <= random.nextInt(2); i++) randomTree(depth + 1),
    ],
  );

  List<String> queries() {
    final k = dataKeys[random.nextInt(dataKeys.length)];
    final sub = dataKeys[random.nextInt(dataKeys.length)];
    final child = nodeKeys[random.nextInt(nodeKeys.length)];
    return [
      '#$k',
      './#$k',
      '../#$k',
      '$child#$k',
      './$child#$k',
      '#$k/$sub',
      '#$k[0]',
      '#$k[0]/$sub',
      '/#$k',
      '#',
      '#node/key',
    ];
  }

  /// Follows a blocker location like '/a/b#x/y[0]' to its value.
  Object? valueAt(Tree<Json> root, String location) {
    final parts = location.split('#');
    final nodePath = parts.first;
    var node = root;
    for (final segment in nodePath.split('/')) {
      if (segment.isEmpty) continue;
      node = node.childByPath(segment);
    }
    Object? cur = node.data;
    for (final segment in parseJsonPath(parts.sublist(1).join('#'))) {
      final (key, indices) = parseArrayIndex(segment);
      cur = (cur as Map)[key];
      for (final index in indices) {
        cur = (cur as List)[index];
      }
    }
    return cur;
  }

  group('readQuery() conformance with Tree.getOrNull', () {
    test('should agree with the real read over a random corpus', () {
      var checkedValues = 0;
      var checkedBlocked = 0;

      for (var iteration = 0; iteration < 120; iteration++) {
        final root = randomTree(0);
        final nodes = root.lsNodes().toList();
        final node = nodes[random.nextInt(nodes.length)];

        for (final query in queries()) {
          final clue =
              'iteration $iteration, node ${node.path}, '
              'query "$query"';

          ReadResult scanned;
          Object? thrown;
          try {
            scanned = readQuery(node, query);
          } on QueryException catch (e) {
            thrown = e;
            scanned = const ReadMissing();
          }

          Object? real;
          Object? realError;
          try {
            real = node.getOrNull<dynamic>(query);
          } catch (e) {
            realError = e;
          }

          if (thrown != null) {
            // readQuery only throws when the real read throws.
            expect(realError, isNotNull, reason: clue);
            continue;
          }

          switch (scanned) {
            case ReadValue(:final value):
              expect(realError, isNull, reason: clue);
              expect(real, value, reason: clue);
              expect(containsMarker(value), isFalse, reason: clue);
              checkedValues++;
            case ReadMissing():
              expect(realError, isNull, reason: clue);
              expect(real, isNull, reason: clue);
            case ReadBlocked(:final blocker):
              // The reported blocker location really holds an
              // unresolved marker (at it or below it).
              expect(
                containsMarker(valueAt(root, blocker)),
                isTrue,
                reason: '$clue, blocker "$blocker"',
              );
              checkedBlocked++;
          }
        }
      }

      // The corpus exercised both interesting outcomes.
      expect(checkedValues, greaterThan(100));
      expect(checkedBlocked, greaterThan(100));
    });
  });
}
