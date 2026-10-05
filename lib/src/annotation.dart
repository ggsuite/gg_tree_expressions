// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';

/// What one rule contributes to one node, see [Resolver.annotate].
///
/// The [value] is a fresh copy per call: mutating it is safe.
class Annotation {
  /// Creates the annotation of variant [variantIndex] of [ruleKey].
  const Annotation({
    required this.ruleKey,
    required this.variantIndex,
    this.value,
  });

  /// An example: what [RuleBook.example]'s `borderHelp` yields.
  factory Annotation.example() => const Annotation(
    ruleKey: 'borderHelp',
    variantIndex: 0,
    value: {'unit': 'px', 'text': 'Width of the dialog border.'},
  );

  /// The key of the rule that annotates the node.
  final String ruleKey;

  /// The index of the winning variant in the merged rule.
  final int variantIndex;

  /// The literal `value` of the variant, or its evaluated `expression`.
  final Object? value;

  // ...........................................................................
  /// A human-readable one-liner.
  @override
  String toString() => '$ruleKey[$variantIndex] = $value';

  /// JSON representation.
  Json toJson() => {
    'ruleKey': ruleKey,
    'variantIndex': variantIndex,
    'value': value,
  };
}
