// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';

import 'did_you_mean.dart';
import 'rule.dart';
import 'tree_expressions_exception.dart';

/// A JSON document mapping rule keys to rule definitions.
class RuleBook {
  RuleBook._(this._rules);

  /// Creates an empty rule book (inline expressions still resolve).
  factory RuleBook.empty() => RuleBook._({});

  /// Parses and validates a rule book from JSON.
  ///
  /// All invalid rules are reported together in one exception.
  factory RuleBook.fromJson(Json json) {
    final rules = <String, Rule>{};
    final errors = <String>[];
    for (final MapEntry(:key, :value) in json.entries) {
      try {
        rules[key] = Rule.fromJson(key, value);
      } on TreeExpressionsException catch (e) {
        errors.addAll(e.messages);
        errors.add('');
      }
    }
    if (errors.isNotEmpty) {
      throw SchemaException([
        'Invalid rule book:',
        '',
        ...errors.sublist(0, errors.length - 1),
      ]);
    }
    return RuleBook._(rules);
  }

  /// Merges [booksInAscendingPriority] into one book.
  ///
  /// Variant lists are concatenated per rule key (e.g. global → vendor
  /// → catalog → item). A later book overrides an earlier one with a
  /// more specific selector; two variants matching at the same
  /// specificity are an ambiguity error, not resolved by order.
  /// (Order still decides a rule's `optional`/`resultType`: the last
  /// book to declare either wins.)
  factory RuleBook.merge(Iterable<RuleBook> booksInAscendingPriority) {
    final rules = <String, Rule>{};
    for (final book in booksInAscendingPriority) {
      for (final MapEntry(:key, :value) in book._rules.entries) {
        final existing = rules[key];
        rules[key] = existing == null ? value : existing.merged(value);
      }
    }
    return RuleBook._(rules);
  }

  /// An example rule book covering the shorthand and object forms.
  ///
  /// A typed multi-variant rule ([Rule.example]), a shorthand base
  /// rule, and an optional rule without a base variant.
  factory RuleBook.example() => RuleBook.fromJson(<String, dynamic>{
    'borderWidth': Rule.example().toJson(),
    'gap': [
      {'expression': '8.0'},
    ],
    'decoration': {
      'optional': true,
      'variants': [
        {
          'selector': {'#style': 'fancy'},
          'expression': '"gold"',
        },
      ],
    },
  });

  final Map<String, Rule> _rules;

  /// The keys of all rules in this book.
  Iterable<String> get keys => _rules.keys;

  /// Returns the rule for [key], or null when unknown.
  Rule? ruleForKey(String key) => _rules[key];

  /// Returns keys similar to the unknown [key], best match first.
  List<String> suggestionsFor(String key) => didYouMean(key, keys);

  /// Serializes the rule book back to JSON.
  Json toJson() => {
    for (final MapEntry(:key, :value) in _rules.entries) key: value.toJson(),
  };

  // ...........................................................................
  /// Reports suspicious but legal setups, one finding per line:
  /// identical variants under different keys, identical selectors
  /// within one rule, and non-optional rules without a base variant.
  List<String> lint() {
    final findings = <String>[];
    final entries = _rules.entries.toList();

    for (var a = 0; a < entries.length; a++) {
      final rule = entries[a].value;

      // Identical rule content under different names.
      for (var b = a + 1; b < entries.length; b++) {
        if (deeplEquals(
          {'v': entries[a].value.toJson()},
          {'v': entries[b].value.toJson()},
        )) {
          findings.add(
            'Rules "${entries[a].key}" and "${entries[b].key}" are '
            'identical — one of them is probably a leftover.',
          );
        }
      }

      // Identical selectors (and `when`) within one rule. Variants that
      // differ only by `when` are not flagged — their predicates may be
      // mutually exclusive.
      for (var i = 0; i < rule.variants.length; i++) {
        for (var j = i + 1; j < rule.variants.length; j++) {
          final vi = rule.variants[i];
          final vj = rule.variants[j];
          if (deeplEquals(vi.selector.toJson(), vj.selector.toJson()) &&
              vi.when == vj.when) {
            final also = vi.when == null ? '' : ' and `when` predicates';
            findings.add(
              'Rule "${rule.key}": variants $i and $j have identical '
              'selectors$also — a node matching them resolves '
              'ambiguously.',
            );
          }
        }
      }

      // No base variant.
      final hasBase = rule.variants.any((v) => v.selector.conditions.isEmpty);
      if (!hasBase && !rule.isOptional) {
        findings.add(
          'Rule "${rule.key}" has no base variant and is not '
          'optional — nodes matching no selector will fail to '
          'resolve.',
        );
      }
    }
    return findings;
  }
}
