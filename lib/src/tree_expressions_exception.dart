// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// Base of all exceptions thrown by gg_tree_expressions.
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
/// An invalid rule book, rule, variant, selector, input or inline
/// expression.
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
/// A tree query is invalid or cannot be read.
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
/// Two or more variants of a rule match a node at the same rank.
class AmbiguousVariantException extends TreeExpressionsException {
  /// Creates the exception.
  AmbiguousVariantException(
    super.messages, {
    required this.ruleKey,
    required this.location,
    required this.specificity,
    required this.variantIndices,
    this.priority = 0,
  });

  /// The rule with the tied variants.
  final String ruleKey;

  /// The tree location of the reference.
  final String location;

  /// The shared specificity of the tied variants.
  final int specificity;

  /// The shared priority of the tied variants.
  final int priority;

  /// The indices of the tied variants, in rule order.
  final List<int> variantIndices;
}

// .............................................................................
/// An input without a default resolved to nothing.
class MissingInputException extends TreeExpressionsException {
  /// Creates the exception.
  MissingInputException(
    super.messages, {
    required this.inputName,
    required this.query,
  });

  /// The name of the unresolvable input.
  final String inputName;

  /// The query or context path that resolved to nothing.
  final String query;
}

// .............................................................................
/// A resolution round made no progress while items remain.
class StuckException extends TreeExpressionsException {
  /// Creates the exception.
  StuckException(super.messages, {required this.pending});

  /// One description per pending item, with its blocker.
  final List<String> pending;
}

// .............................................................................
/// Any other resolution failure, e.g. a result of the wrong type.
class ResolveException extends TreeExpressionsException {
  /// Creates the exception.
  ResolveException(super.messages);
}
