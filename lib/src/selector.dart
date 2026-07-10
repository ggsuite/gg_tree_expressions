// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';

import 'tree_expressions_exception.dart';
import 'tree_reader.dart';

// .............................................................................
/// The outcome of matching a selector at a node.
sealed class MatchResult {
  const MatchResult();
}

/// All conditions hold.
class MatchSuccess extends MatchResult {
  /// Creates the result.
  const MatchSuccess();
}

/// A condition failed.
class MatchFailure extends MatchResult {
  /// Creates the result for the first failing condition.
  const MatchFailure(this.query, this.expected, this.actual);

  /// The query of the failing condition.
  final String query;

  /// The literal the condition expected.
  final Object expected;

  /// The value found, or null when the query resolved to nothing.
  final Object? actual;

  /// A human-readable failure description.
  String get reason => actual == null
      ? 'condition "$query == $expected" failed: no value found'
      : 'condition "$query == $expected" failed: found "$actual"';
}

/// A condition read a still-unresolved value; matching must be
/// retried after further resolution.
class MatchBlocked extends MatchResult {
  /// Creates the result naming the blocking [query] and [blocker].
  const MatchBlocked(this.query, this.blocker);

  /// The query of the blocked condition.
  final String query;

  /// The location of the unresolved value.
  final String blocker;
}

// .............................................................................
/// A set of `treeQuery == literal` conditions deciding whether a rule
/// variant applies at a node. All conditions must hold (AND).
class Selector {
  /// Creates a selector from validated [conditions].
  Selector(this.conditions);

  /// Parses and validates a selector from rule book JSON.
  ///
  /// [context] describes the owner (e.g. a rule key) for errors.
  /// `null` yields [Selector.none].
  factory Selector.fromJson(Object? json, {required String context}) {
    if (json == null) return none;
    if (json is! Map) {
      throw SchemaException([
        'The selector in $context must be a JSON object '
            'mapping tree queries to literals.',
        'Got: $json',
      ]);
    }

    final conditions = <String, Object>{};
    for (final MapEntry(:key, :value) in json.entries) {
      final query = key as String;
      validateQuery(query, context: 'the selector of $context');
      if (value is! String && value is! num && value is! bool) {
        throw SchemaException([
          'Selector condition "$query" in $context has an invalid '
              'literal: $value (${value.runtimeType}).',
          'Literals must be a string, a number, or a bool. '
              'Null is not allowed — gg_tree treats null values as '
              'missing.',
        ]);
      }
      conditions[query] = value as Object;
    }
    return Selector(conditions);
  }

  /// The empty selector matching everywhere (base variant).
  static final Selector none = Selector(const {});

  /// The conditions: tree query → expected scalar literal.
  final Map<String, Object> conditions;

  /// The number of conditions; more specific selectors win.
  int get specificity => conditions.length;

  /// Serializes the selector back to JSON.
  Json toJson() => Map<String, dynamic>.of(conditions);

  // ...........................................................................
  /// Matches this selector at [node].
  ///
  /// A query resolving to nothing — including a shape mismatch — makes
  /// the condition fail; only unresolved markers block.
  ///
  /// A [readCache], if given, memoizes reads across a [Rule.select]
  /// call so a condition query shared by several variants is read once.
  MatchResult match(Tree<Json> node, {Map<String, ReadResult>? readCache}) {
    for (final MapEntry(key: query, value: expected) in conditions.entries) {
      final result = _read(node, query, readCache);

      switch (result) {
        case ReadBlocked(:final blocker):
          return MatchBlocked(query, blocker);
        case ReadMissing():
          return MatchFailure(query, expected, null);
        case ReadValue(:final value):
          if (value != expected) {
            return MatchFailure(query, expected, value);
          }
      }
    }
    return const MatchSuccess();
  }

  // ...........................................................................
  /// Reads [query] at [node], reusing/filling [cache] when present.
  /// Query errors are treated as "missing" (a shape mismatch is a
  /// failed condition, not a resolution failure).
  static ReadResult _read(
    Tree<Json> node,
    String query,
    Map<String, ReadResult>? cache,
  ) {
    final cached = cache?[query];
    if (cached != null) return cached;

    ReadResult result;
    try {
      result = readQuery(node, query);
    } on TreeExpressionsException {
      result = const ReadMissing();
    }
    cache?[query] = result;
    return result;
  }
}
