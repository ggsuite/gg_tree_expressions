// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';

import 'rule_input.dart';
import 'selector.dart';
import 'tree_expressions_exception.dart';

/// Identifiers CEL reserves; they cannot name inputs.
const Set<String> celReservedWords = {
  'true', 'false', 'null', 'in', 'as', 'break', 'const', 'continue', //
  'else', 'for', 'function', 'if', 'import', 'let', 'loop', 'package',
  'namespace', 'return', 'var', 'void', 'while',
};

final RegExp _identifierPattern = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');

/// One concrete definition of a rule: an optional selector, optional
/// inputs, and one CEL expression.
class RuleVariant {
  /// Creates a variant computing [expression].
  RuleVariant({
    required this.expression,
    Selector? selector,
    Map<String, RuleInput>? inputs,
    this.when,
    this.description,
  }) : selector = selector ?? Selector.none,
       inputs = inputs ?? const {};

  /// Parses and validates a variant from rule book JSON.
  ///
  /// [context] describes the owner (e.g. `'rule "x", variant 2'`)
  /// for errors.
  factory RuleVariant.fromJson(Object? json, {required String context}) {
    if (json is! Map) {
      throw SchemaException(['$context must be a JSON object, got: $json']);
    }

    const allowed = {'selector', 'when', 'inputs', 'expression', 'description'};
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

    final expression = json['expression'];
    if (expression is! String || expression.trim().isEmpty) {
      throw SchemaException([
        'Missing or empty "expression" in $context.',
        'Every variant needs a CEL expression string.',
      ]);
    }

    final when = json['when'];
    if (when != null && (when is! String || when.trim().isEmpty)) {
      throw SchemaException([
        'The "when" predicate of $context must be a non-empty CEL '
            'string, got: $when',
      ]);
    }

    final description = json['description'];
    if (description != null && description is! String) {
      throw SchemaException([
        'The "description" of $context must be a string, '
            'got: $description',
      ]);
    }

    return RuleVariant(
      expression: expression,
      selector: Selector.fromJson(json['selector'], context: context),
      inputs: _inputsFromJson(json['inputs'], context: context),
      when: when as String?,
      description: description as String?,
    );
  }

  /// An example override variant applied to small dark-mode mobile
  /// screens.
  factory RuleVariant.example() => RuleVariant(
    expression: 'screenWidth < 400.0 ? 3.0 : 2.0',
    selector: Selector.example(),
    inputs: {'screenWidth': RuleInput.example()},
    description: 'Thicker borders on small dark-mode screens.',
  );

  /// The CEL expression computing the rule result.
  final String expression;

  /// The conditions for this variant to apply; [Selector.none] marks
  /// the base variant.
  final Selector selector;

  /// An optional CEL predicate (evaluating to bool) that must also hold
  /// for this variant to apply, in addition to the [selector]. It reads
  /// tree values through the same [inputs] as [expression]; null when
  /// absent.
  final String? when;

  /// Bindings from CEL identifiers to tree queries.
  final Map<String, RuleInput> inputs;

  /// Documentation only.
  final String? description;

  /// True when a [when] predicate is present. It breaks specificity
  /// ties among variants with the same number of selector conditions.
  bool get hasWhen => when != null;

  // ...........................................................................
  /// Serializes the variant back to JSON.
  Json toJson() => {
    if (selector.conditions.isNotEmpty) 'selector': selector.toJson(),
    if (when != null) 'when': when,
    if (inputs.isNotEmpty)
      'inputs': {
        for (final MapEntry(:key, :value) in inputs.entries)
          key: value.toJson(),
      },
    'expression': expression,
    if (description != null) 'description': description,
  };

  // ...........................................................................
  static Map<String, RuleInput> _inputsFromJson(
    Object? json, {
    required String context,
  }) {
    if (json == null) return const {};
    if (json is! Map) {
      throw SchemaException([
        'The "inputs" of $context must be a JSON object mapping '
            'CEL identifiers to tree queries.',
        'Got: $json',
      ]);
    }

    final inputs = <String, RuleInput>{};
    for (final MapEntry(:key, :value) in json.entries) {
      final identifier = key as String;
      if (!_identifierPattern.hasMatch(identifier) ||
          celReservedWords.contains(identifier)) {
        throw SchemaException([
          '"$identifier" is not a valid CEL identifier '
              '(input of $context).',
          'Identifiers match [a-zA-Z_][a-zA-Z0-9_]* and must not be '
              'a CEL reserved word.',
        ]);
      }
      inputs[identifier] = RuleInput.fromJson(
        value,
        context: 'input "$identifier" of $context',
      );
    }
    return inputs;
  }
}
