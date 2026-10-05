// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';

import 'tree_expressions_exception.dart';
import 'tree_reader.dart';

/// A named binding from a CEL identifier to a value, evaluated relative
/// to the node holding the reference: either a tree [query] or a path
/// into the resolver's caller [context].
class RuleInput {
  /// Creates an input reading exactly one of [query] and [context],
  /// optionally with a default.
  RuleInput({
    this.query,
    this.context,
    this.defaultValue,
    this.hasDefault = false,
  }) : assert((query == null) != (context == null), 'query xor context');

  /// Parses an input from rule book JSON.
  ///
  /// Accepts the short form (a query string) and the long form
  /// (`{"query": …, "default": …}` or `{"context": …, "default": …}`).
  /// [context] describes the owner for errors.
  factory RuleInput.fromJson(Object? json, {required String context}) {
    if (json is String) {
      validateQuery(json, context: context);
      return RuleInput(query: json);
    }

    if (json is Map) {
      const allowed = {'query', 'context', 'default'};
      final unknown = json.keys.where((k) => !allowed.contains(k));
      if (unknown.isNotEmpty) {
        throw SchemaException([
          'Unknown key(s) ${unknown.map((k) => '"$k"').join(', ')} '
              'in $context.',
          '',
          'Allowed keys:',
          ...allowed.map((k) => '  - $k'),
        ]);
      }

      final hasContext = json.containsKey('context');
      if (hasContext && json.containsKey('query')) {
        throw SchemaException([
          '$context has both "query" and "context".',
          'An input reads exactly one: a tree "query" or a "context" '
              'path.',
        ]);
      }

      final String? query;
      final String? contextPath;
      if (hasContext) {
        final path = json['context'];
        if (path is! String) {
          throw SchemaException([
            'Invalid "context" in $context.',
            'Expected a context path string, got: $path',
          ]);
        }
        validateContextPath(path, context: context);
        query = null;
        contextPath = path;
      } else {
        final value = json['query'];
        if (value is! String) {
          throw SchemaException([
            'Missing or invalid "query" in $context.',
            'Expected a tree query string, got: $value',
            'An input needs exactly one of "query" (a tree query) or '
                '"context" (a caller context path).',
          ]);
        }
        validateQuery(value, context: context);
        query = value;
        contextPath = null;
      }

      final hasDefault = json.containsKey('default');
      final defaultValue = json['default'];
      if (hasDefault && !isJsonValue(defaultValue)) {
        throw SchemaException([
          'The default of $context is not a JSON value: '
              '$defaultValue (${defaultValue.runtimeType}).',
        ]);
      }
      return RuleInput(
        query: query,
        context: contextPath,
        defaultValue: defaultValue,
        hasDefault: hasDefault,
      );
    }

    throw SchemaException([
      'Invalid input definition in $context: $json',
      'Expected a query string, {"query": …, "default": …} or '
          '{"context": …, "default": …}.',
    ]);
  }

  /// An example input (long form) reading `screen#width`, defaulting to
  /// `4.0`. The short form is just the query string (e.g. `'#width'`).
  factory RuleInput.example() =>
      RuleInput(query: 'screen#width', defaultValue: 4.0, hasDefault: true);

  /// The tree query bound to the CEL identifier; null for a [context]
  /// input.
  final String? query;

  /// The data path (`a/b`, `a.b`, `xs[0]`, …) into the resolver's caller
  /// context bound to the CEL identifier; null for a [query] input.
  final String? context;

  /// The value used when the query or context path resolves to nothing.
  final Object? defaultValue;

  /// True when a default was declared. Without one, an unresolvable
  /// query or context path is an error.
  final bool hasDefault;

  /// True when this input reads the caller [context], not the tree.
  bool get isContext => context != null;

  /// Serializes back to JSON (short form when possible).
  Object? toJson() {
    if (!isContext && !hasDefault) return query;
    return {
      if (isContext) 'context': context else 'query': query,
      if (hasDefault) 'default': defaultValue,
    };
  }
}
