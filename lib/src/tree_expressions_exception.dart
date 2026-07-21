// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// Base of all exceptions thrown by gg_tree_expressions.
///
/// Carries one logical line per list element. The first line states
/// the problem, usually quoting the offending rule key, query, or
/// node path. Following lines add remediation hints or available
/// alternatives, indented with `'  - '`.
///
/// The hierarchy is sealed — consumers can match exhaustively or
/// catch individual categories instead of parsing messages.
sealed class TreeExpressionsException implements Exception {
  /// Creates an exception from [messages], one logical line each.
  TreeExpressionsException(this.messages);

  /// The message lines.
  final List<String> messages;

  /// All lines joined into a single message.
  String get message => messages.join('\n');

  @override
  String toString() => message;
}

// .............................................................................
/// Invalid rule book, rule, variant, selector, input, or inline
/// expression definitions — authoring errors caught at load time or
/// when an inline map is first processed.
class SchemaException extends TreeExpressionsException {
  /// Creates the exception.
  SchemaException(super.messages);
}

// .............................................................................
/// A CEL expression failed to compile or evaluate.
class ExpressionException extends TreeExpressionsException {
  /// Creates the exception for [expression].
  ExpressionException(super.messages, {required this.expression});

  /// The offending expression source.
  final String expression;
}

// .............................................................................
/// A tree query failed at resolution time (invalid syntax or a data
/// path traversing an incompatible shape).
class QueryException extends TreeExpressionsException {
  /// Creates the exception for [query] at [nodePath].
  QueryException(super.messages, {required this.query, required this.nodePath});

  /// The offending query.
  final String query;

  /// The path of the node the query was evaluated from.
  final String nodePath;
}

// .............................................................................
/// A reference names a rule the rule book does not contain.
class UnknownRuleException extends TreeExpressionsException {
  /// Creates the exception.
  UnknownRuleException(
    super.messages, {
    required this.ruleKey,
    required this.location,
    this.suggestions = const [],
  });

  /// The unknown rule key.
  final String ruleKey;

  /// The tree location of the reference.
  final String location;

  /// Similar existing rule keys, best match first.
  final List<String> suggestions;
}

// .............................................................................
/// Rule aliases form a cycle.
class CircularAliasException extends TreeExpressionsException {
  /// Creates the exception.
  CircularAliasException(
    super.messages, {
    required this.chain,
    required this.location,
  });

  /// The rule keys forming the cycle, in application order.
  final List<String> chain;

  /// The tree location where the cycle was detected.
  final String location;
}

// .............................................................................
/// No variant of a non-optional rule matched at a node.
class NoVariantException extends TreeExpressionsException {
  /// Creates the exception.
  NoVariantException(
    super.messages, {
    required this.ruleKey,
    required this.location,
    required this.reasons,
  });

  /// The rule whose variants all failed.
  final String ruleKey;

  /// The tree location of the reference.
  final String location;

  /// Why each variant did not match.
  final List<String> reasons;
}

// .............................................................................
/// Two or more variants of a rule match a node at the same specificity,
/// so the winner is ambiguous. Ties are never broken silently — the
/// selectors must be specific enough that exactly one variant wins.
class AmbiguousVariantException extends TreeExpressionsException {
  /// Creates the exception.
  AmbiguousVariantException(
    super.messages, {
    required this.ruleKey,
    required this.location,
    required this.specificity,
    required this.variantIndices,
  });

  /// The rule with the tied variants.
  final String ruleKey;

  /// The tree location of the reference.
  final String location;

  /// The shared specificity of the tied variants.
  final int specificity;

  /// The indices of the tied variants, in rule order.
  final List<int> variantIndices;
}

// .............................................................................
/// An input query resolved to nothing and declared no default.
class MissingInputException extends TreeExpressionsException {
  /// Creates the exception.
  MissingInputException(
    super.messages, {
    required this.inputName,
    required this.query,
  });

  /// The name of the unresolvable input.
  final String inputName;

  /// The query that resolved to nothing.
  final String query;
}

// .............................................................................
/// A resolution round made no progress while items remain — rules
/// wait on each other in a cycle or on values that never resolve.
class StuckException extends TreeExpressionsException {
  /// Creates the exception.
  StuckException(super.messages, {required this.pending});

  /// One description per pending item, with its blocker.
  final List<String> pending;
}

// .............................................................................
/// Other resolution failures: non-root copy mode, uncopyable trees,
/// result-type violations, and expressions that never settle.
class ResolveException extends TreeExpressionsException {
  /// Creates the exception.
  ResolveException(super.messages);
}
