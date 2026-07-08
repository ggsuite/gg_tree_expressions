// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Property-style harness for the resolver's core claims: resolution
// leaves no markers behind, is idempotent, keeps the original intact
// in copy mode, and its outcome does not depend on the order in
// which references appear in node data.

import 'dart:math';

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';
import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  final random = Random(20260708);

  /// A random rule book. Aliases only point to higher rule indices,
  /// so books are cycle-free by construction.
  Json randomBook(int ruleCount) {
    final book = <String, dynamic>{};
    for (var i = 0; i < ruleCount; i++) {
      final expressions = [
        '1.0 * ${i + 1}',
        "'txt$i'",
        'true',
        '[1, $i]',
        "{'nested': $i}",
        if (i < ruleCount - 1)
          "{'§': '§r${i + 1 + random.nextInt(ruleCount - 1 - i)}'}",
      ];
      book['§r$i'] = [
        {
          if (random.nextBool())
            'inputs': {
              'a': {'query': '#seed', 'default': 1},
            },
          'expression': random.nextBool()
              ? expressions[random.nextInt(expressions.length)]
              : 'a + $i',
        },
        if (random.nextBool())
          {
            'selector': {'#flag': true},
            'expression': '${i + 100}',
          },
      ];
      // Rules without the 'a' input must not use it.
      final variants = book['§r$i'] as List;
      final base = variants.first as Map;
      if (!base.containsKey('inputs') && base['expression'] == 'a + $i') {
        base['expression'] = '$i';
      }
    }
    return book;
  }

  Object? randomValue(int ruleCount, int depth) {
    final roll = random.nextInt(8);
    if (roll == 0) return {'§': '§r${random.nextInt(ruleCount)}'};
    if (roll == 1) return {'§expression': '2 * ${random.nextInt(5)}'};
    if (roll == 2 && depth < 2) {
      return {
        'inner': randomValue(ruleCount, depth + 1),
        if (random.nextBool()) 'other': randomValue(ruleCount, depth + 1),
      };
    }
    if (roll == 3 && depth < 2) {
      return [randomValue(ruleCount, depth + 1), 7];
    }
    return switch (roll % 3) {
      0 => random.nextInt(50),
      1 => 'v${random.nextInt(3)}',
      _ => random.nextBool(),
    };
  }

  Json randomData(int ruleCount) => {
    'seed': random.nextInt(5),
    if (random.nextBool()) 'flag': random.nextBool(),
    for (var i = 0; i < 1 + random.nextInt(3); i++)
      'k$i': randomValue(ruleCount, 0),
  };

  Tree<Json> randomTree(int ruleCount, int depth) => Tree<Json>(
    key: depth == 0 ? 'root' : 'n${random.nextInt(1000)}',
    data: randomData(ruleCount),
    children: [
      if (depth < 2)
        for (var i = 0; i <= random.nextInt(2); i++)
          randomTree(ruleCount, depth + 1),
    ],
  );

  /// Rebuilds [tree] with reversed data-entry order everywhere —
  /// same content, different worklist order.
  Tree<Json> reversedClone(Tree<Json> tree) => Tree<Json>(
    key: tree.key,
    data: Map.fromEntries(tree.data.entries.toList().reversed),
    children: [for (final child in tree.children) reversedClone(child)],
  );

  bool treeIsMarkerFree(Tree<Json> tree) {
    var clean = true;
    tree.visit((node) {
      if (node.data.values.any(containsMarker)) clean = false;
    });
    return clean;
  }

  group('Resolver properties', () {
    test('should uphold its invariants over a random corpus', () {
      for (var iteration = 0; iteration < 60; iteration++) {
        final ruleCount = 2 + random.nextInt(4);
        final resolver = Resolver(
          ruleBook: RuleBook.fromJson(randomBook(ruleCount)),
        );
        final tree = randomTree(ruleCount, 0);
        final before = tree.toJson();
        final clue = 'iteration $iteration';

        // 1. Resolution succeeds (books are cycle-free with base
        //    variants and defaulted inputs) and removes every marker.
        final resolved = resolver.resolve(tree);
        expect(treeIsMarkerFree(resolved), isTrue, reason: clue);

        // 2. Copy mode leaves the original untouched.
        expect(deeplEquals(tree.toJson(), before), isTrue, reason: clue);

        // 3. Idempotent: resolving the result changes nothing.
        final again = resolver.resolve(resolved);
        expect(
          deeplEquals(again.toJson(), resolved.toJson()),
          isTrue,
          reason: clue,
        );

        // 4. Order-independent: reversed data-entry order resolves
        //    to the same values.
        final reversed = resolver.resolve(reversedClone(tree));
        expect(
          deeplEquals(reversed.toJson(), resolved.toJson()),
          isTrue,
          reason: clue,
        );
      }
    });
  });
}
