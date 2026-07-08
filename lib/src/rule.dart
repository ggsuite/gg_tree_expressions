// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';

import 'result_type.dart';
import 'rule_ref.dart';
import 'rule_variant.dart';
import 'selector.dart';
import 'tree_expressions_exception.dart';

// .............................................................................
/// The outcome of selecting a variant of a rule at a node.
sealed class SelectResult {
  const SelectResult();
}

/// A variant was selected.
class SelectMatch extends SelectResult {
  /// Creates the result carrying the winning [variant] and its
  /// [index] in the merged variant list.
  const SelectMatch(this.variant, this.index);

  /// The winning variant.
  final RuleVariant variant;

  /// The index of the winning variant.
  final int index;
}

/// No variant matched.
class SelectNone extends SelectResult {
  /// Creates the result carrying one failure [reasons] line per
  /// variant.
  const SelectNone(this.reasons);

  /// Why each variant did not match.
  final List<String> reasons;
}

/// A selector read a still-unresolved value that could change the
/// outcome; selection must be retried after further resolution.
class SelectBlocked extends SelectResult {
  /// Creates the result naming the blocking [query] and [blocker].
  const SelectBlocked(this.query, this.blocker);

  /// The query of the blocked selector condition.
  final String query;

  /// The location of the unresolved value.
  final String blocker;
}

// .............................................................................
/// A named unit consisting of one or more variants.
class Rule {
  /// Creates a rule with [key] and [variants].
  Rule({
    required this.key,
    required this.variants,
    this.optionalFlag,
    this.resultType,
  });

  /// Parses and validates the rule [key] and its definition [json].
  ///
  /// Accepts the shorthand (a plain variant list) and the object form
  /// (`{"optional": …, "resultType": …, "variants": [...]}`).
  factory Rule.fromJson(String key, Object? json) {
    if (!isRuleKey(key)) {
      throw SchemaException([
        'Invalid rule key "$key".',
        'Rule keys match ${ruleKeyPattern.pattern} — a "§" followed '
            'by a letter and letters, digits, or underscores '
            '(e.g. "§borderWidth").',
      ]);
    }

    bool? optionalFlag;
    ResultType? resultType;
    Object? variantsJson = json;

    if (json is Map && json.containsKey('variants')) {
      const allowed = {'optional', 'resultType', 'variants'};
      final unknown = json.keys.where((k) => !allowed.contains(k));
      if (unknown.isNotEmpty) {
        throw SchemaException([
          'Unknown key(s) ${unknown.map((k) => '"$k"').join(', ')} '
              'in rule "$key".',
          '',
          'Allowed keys:',
          ...allowed.map((k) => '  - $k'),
        ]);
      }

      final optional = json['optional'];
      if (optional != null && optional is! bool) {
        throw SchemaException([
          'The "optional" flag of rule "$key" must be a bool, '
              'got: $optional',
        ]);
      }
      optionalFlag = optional as bool?;

      final resultTypeJson = json['resultType'];
      if (resultTypeJson != null) {
        resultType = ResultType.fromJson(
          resultTypeJson,
          context: 'rule "$key"',
        );
      }
      variantsJson = json['variants'];
    }

    if (variantsJson is! List || variantsJson.isEmpty) {
      throw SchemaException([
        'Rule "$key" must define a non-empty list of variants.',
        'Got: $variantsJson',
      ]);
    }

    final variants = <RuleVariant>[];
    for (var i = 0; i < variantsJson.length; i++) {
      variants.add(
        RuleVariant.fromJson(
          variantsJson[i],
          context: 'rule "$key", variant $i',
        ),
      );
    }

    return Rule(
      key: key,
      variants: variants,
      optionalFlag: optionalFlag,
      resultType: resultType,
    );
  }

  /// The rule key, including the `§` prefix.
  final String key;

  /// The variants in merged rule book order.
  final List<RuleVariant> variants;

  /// The raw optional flag; null when never declared.
  final bool? optionalFlag;

  /// True when "no variant matched" removes the reference instead of
  /// erroring.
  bool get isOptional => optionalFlag ?? false;

  /// Optional validation of resolved results.
  final ResultType? resultType;

  // ...........................................................................
  /// Selects the winning variant at [node].
  ///
  /// The variant with the highest selector specificity wins; ties go
  /// to the later variant. Returns [SelectBlocked] when a blocked
  /// variant could still outrank the current winner.
  SelectResult select(Tree<Json> node) {
    RuleVariant? bestVariant;
    var bestIndex = -1;
    var bestSpecificity = -1;
    final reasons = <String>[];
    SelectBlocked? blocked;
    var blockedSpecificity = -1;
    var blockedIndex = -1;

    for (var i = 0; i < variants.length; i++) {
      final variant = variants[i];
      final specificity = variant.selector.specificity;
      switch (variant.selector.match(node)) {
        case MatchSuccess():
          if (specificity > bestSpecificity ||
              (specificity == bestSpecificity && i > bestIndex)) {
            bestVariant = variant;
            bestIndex = i;
            bestSpecificity = specificity;
          }
        case MatchFailure(:final reason):
          reasons.add('variant $i: $reason');
        case MatchBlocked(:final query, :final blocker):
          if (specificity > blockedSpecificity ||
              (specificity == blockedSpecificity && i > blockedIndex)) {
            blocked = SelectBlocked(query, blocker);
            blockedSpecificity = specificity;
            blockedIndex = i;
          }
      }
    }

    // A blocked variant only matters when it could beat the winner.
    if (blocked != null &&
        (blockedSpecificity > bestSpecificity ||
            (blockedSpecificity == bestSpecificity &&
                blockedIndex > bestIndex))) {
      return blocked;
    }

    if (bestVariant != null) return SelectMatch(bestVariant, bestIndex);
    return SelectNone(reasons);
  }

  // ...........................................................................
  /// Returns this rule merged with [other] (higher priority).
  ///
  /// Variants are concatenated; conflicting `optional`/`resultType`
  /// declarations are an error.
  Rule merged(Rule other) {
    if (other.key != key) {
      throw SchemaException([
        'Cannot merge rule "${other.key}" into rule "$key".',
      ]);
    }
    if (optionalFlag != null &&
        other.optionalFlag != null &&
        optionalFlag != other.optionalFlag) {
      throw SchemaException([
        'Conflicting "optional" flags for rule "$key" while merging '
            'rule books: $optionalFlag vs ${other.optionalFlag}.',
      ]);
    }
    if (resultType != null &&
        other.resultType != null &&
        resultType != other.resultType) {
      throw SchemaException([
        'Conflicting result types for rule "$key" while merging '
            'rule books: ${resultType!.jsonValue} vs '
            '${other.resultType!.jsonValue}.',
      ]);
    }

    return Rule(
      key: key,
      variants: [...variants, ...other.variants],
      optionalFlag: other.optionalFlag ?? optionalFlag,
      resultType: other.resultType ?? resultType,
    );
  }

  // ...........................................................................
  /// Serializes the rule definition back to JSON (shorthand when no
  /// rule-level fields are set).
  Object toJson() {
    final variantsJson = variants.map((v) => v.toJson()).toList();
    if (optionalFlag == null && resultType == null) return variantsJson;
    return <String, dynamic>{
      if (optionalFlag != null) 'optional': optionalFlag,
      if (resultType != null) 'resultType': resultType!.jsonValue,
      'variants': variantsJson,
    };
  }
}
