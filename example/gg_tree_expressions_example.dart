#!/usr/bin/env dart
// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';
import 'package:gg_tree_expressions/gg_tree_expressions.dart';

void main() {
  // A rule book: rules are lists of variants; the most specific
  // matching selector wins.
  final ruleBook = RuleBook.fromJson({
    'borderWidth': [
      {'expression': '1.0'},
      {
        'selector': {'theme#id': 'dark'},
        'expression': '2.0',
      },
      {
        'selector': {'theme#id': 'dark', '#platform': 'mobile'},
        'inputs': {'screenWidth': 'screen#width'},
        'expression': 'screenWidth < 400.0 ? 3.0 : 2.0',
      },
    ],
  });

  // A tree whose dialog asks for the border width.
  final app = Tree<Json>(
    key: 'app',
    data: {'platform': 'mobile'},
    children: [
      Tree<Json>(key: 'theme', data: {'id': 'dark'}),
      Tree<Json>(key: 'screen', data: {'width': 380.0}),
      Tree<Json>(
        key: 'dialog',
        data: {
          'borderWidth': {'§': 'borderWidth'},
        },
      ),
    ],
  );

  // One call resolves every reference in node context.
  final resolved = Resolver(ruleBook: ruleBook).resolve(app);
  final borderWidth = resolved
      .childByPath('dialog')
      .get<double>('./#borderWidth');
  print('dialog.borderWidth: $borderWidth'); // 3.0
}
