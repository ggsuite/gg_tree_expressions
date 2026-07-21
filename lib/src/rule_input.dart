// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';

import 'tree_expressions_exception.dart';
import 'tree_reader.dart';

/// A named binding from a CEL identifier to a tree query, evaluated
/// relative to the node holding the reference.
class RuleInput {
  /// Creates an input reading [query], optionally with a default.
  RuleInput({required this.query, this.defaultValue, this.hasDefault = false});

  /// Parses an input from rule book JSON.
  ///
  /// Accepts the short form (a query string) and the long form
  /// (`{"query": …, "default": …}`). [context] describes the owner
  /// for errors.
  factory RuleInput.fromJson(Object? json, {required String context}) {
    if (json is String) {
      validateQuery(json, context: context);
      return RuleInput(query: json);
    }

    if (json is Map) {
      const allowed = {'query', 'default'};
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

      final query = json['query'];
      if (query is! String) {
        throw SchemaException([
          'Missing or invalid "query" in $context.',
          'Expected a tree query string, got: $query',
        ]);
      }
      validateQuery(query, context: context);

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
        defaultValue: defaultValue,
        hasDefault: hasDefault,
      );
    }

    throw SchemaException([
      'Invalid input definition in $context: $json',
      'Expected a query string or {"query": …, "default": …}.',
    ]);
  }

  /// An example input (long form) reading `screen#width`, defaulting to
  /// `4.0`. The short form is just the query string (e.g. `'#width'`).
  factory RuleInput.example() =>
      RuleInput(query: 'screen#width', defaultValue: 4.0, hasDefault: true);

  /// The tree query bound to the CEL identifier.
  final String query;

  /// The value used when the query resolves to nothing.
  final Object? defaultValue;

  /// True when a default was declared. Without one, an unresolvable
  /// query is an error.
  final bool hasDefault;

  /// Serializes back to JSON (short form when possible).
  Object? toJson() =>
      hasDefault ? {'query': query, 'default': defaultValue} : query;
}
