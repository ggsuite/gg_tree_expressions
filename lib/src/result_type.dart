// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'tree_expressions_exception.dart';

/// Optional result validation for a rule.
///
/// When a rule declares a result type, every resolved value of that
/// rule is checked against it after evaluation.
enum ResultType {
  /// The result must be an int or a double.
  number('number'),

  /// The result must be a string.
  string('string'),

  /// The result must be a bool.
  boolean('bool'),

  /// The result must be a list.
  list('list'),

  /// The result must be a map.
  map('map');

  const ResultType(this.jsonValue);

  /// The value representing this type in rule book JSON.
  final String jsonValue;

  /// Parses [value] into a [ResultType].
  ///
  /// [context] describes the owner (e.g. a rule key) for errors.
  static ResultType fromJson(Object? value, {required String context}) {
    for (final type in ResultType.values) {
      if (value == type.jsonValue) return type;
    }
    throw SchemaException([
      'Invalid resultType "$value" in $context.',
      '',
      'Allowed values:',
      ...ResultType.values.map((t) => '  - ${t.jsonValue}'),
    ]);
  }

  /// Returns true when [value] conforms to this type.
  bool accepts(Object? value) => switch (this) {
    number => value is num,
    string => value is String,
    boolean => value is bool,
    list => value is List,
    map => value is Map,
  };
}
