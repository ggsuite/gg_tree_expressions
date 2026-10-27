// @license
// Copyright (c) ggsuite
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

  /// Creates an empty rule book.
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

  /// Merges [books] into one book, concatenating variants per rule key.
  ///
  /// Throws a [SchemaException] on conflicting `optional` or `resultType`.
  factory RuleBook.merge(Iterable<RuleBook> books) {
    final rules = <String, Rule>{};
    for (final book in books) {
      for (final MapEntry(:key, :value) in book._rules.entries) {
        final existing = rules[key];
        rules[key] = existing == null ? value : existing.merged(value);
      }
    }
    return RuleBook._(rules);
  }

  /// An example rule book covering the shorthand and object forms.
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
    'borderHelp': [
      {
        'value': {'unit': 'px', 'text': 'Width of the dialog border.'},
      },
    ],
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
  /// Reports suspicious but legal setups, one finding per line.
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

      // Identical selector, `when` and priority within one rule.
      for (var i = 0; i < rule.variants.length; i++) {
        for (var j = i + 1; j < rule.variants.length; j++) {
          final vi = rule.variants[i];
          final vj = rule.variants[j];
          if (deeplEquals(vi.selector.toJson(), vj.selector.toJson()) &&
              vi.when == vj.when &&
              vi.priority == vj.priority) {
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
