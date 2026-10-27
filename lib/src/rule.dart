// @license
// Copyright (c) ggsuite
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
import 'tree_reader.dart';

// .............................................................................
/// The outcome of selecting a variant of a rule at a node.
sealed class SelectResult {
  const SelectResult();
}

/// A variant was selected.
class SelectMatch extends SelectResult {
  /// Creates the result for the winning [variant] at [index].
  const SelectMatch(this.variant, this.index);

  /// The winning variant.
  final RuleVariant variant;

  /// The index of the winning variant.
  final int index;
}

/// No variant matched.
class SelectNone extends SelectResult {
  /// Creates the result with the failure [reasons], one per variant.
  const SelectNone(this.reasons);

  /// Why each variant did not match.
  final List<String> reasons;
}

/// A selector read an unresolved value; selection must be retried.
class SelectBlocked extends SelectResult {
  /// Creates the result naming the blocking [query] and [blocker].
  const SelectBlocked(this.query, this.blocker);

  /// The query of the blocked selector condition.
  final String query;

  /// The location of the unresolved value.
  final String blocker;
}

/// Two or more variants match at the winning rank.
class SelectAmbiguous extends SelectResult {
  /// Creates the result for the tied [matches] and their rank.
  const SelectAmbiguous(this.specificity, this.matches, {this.priority = 0});

  /// The selector condition count of the tied variants.
  final int specificity;

  /// The shared [RuleVariant.priority] of the tied variants.
  final int priority;

  /// The tied matching variants, in rule order.
  final List<SelectMatch> matches;
}

// .............................................................................
/// Evaluates a variant's [RuleVariant.when] predicate at a node.
typedef WhenEvaluator = MatchResult Function(
  RuleVariant variant,
  Tree<Json> node,
  int index,
);

/// A variant whose selector matches or is blocked (`selectorBlock`).
typedef _Ranked = ({
  RuleVariant variant,
  int index,
  SelectBlocked? selectorBlock,
});

/// A variant's rank in [Rule.select], compared in field order.
typedef _Rank = ({int conditions, int priority, bool hasWhen});

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
  /// Accepts a plain variant list or the object form.
  factory Rule.fromJson(String key, Object? json) {
    if (!isRuleKey(key)) {
      throw SchemaException([
        'Invalid rule key "$key".',
        'Rule keys match ${ruleKeyPattern.pattern} — a letter '
            'followed by letters, digits, or underscores '
            '(e.g. "borderWidth").',
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

  /// An example rule with a base variant and two overrides.
  factory Rule.example() => Rule(
    key: 'borderWidth',
    variants: [
      RuleVariant(expression: '1.0'),
      RuleVariant(selector: Selector({'theme#id': 'dark'}), expression: '2.0'),
      RuleVariant.example(),
    ],
    resultType: ResultType.number,
  );

  /// The rule key, a plain identifier.
  final String key;

  /// The variants in merged rule book order.
  final List<RuleVariant> variants;

  /// The raw optional flag; null when never declared.
  final bool? optionalFlag;

  /// True when a reference without a matching variant is removed.
  bool get isOptional => optionalFlag ?? false;

  /// Optional validation of resolved results.
  final ResultType? resultType;

  // ...........................................................................
  /// Selects the winning variant at [node].
  ///
  /// Ranks applying variants by selector conditions, then priority, then
  /// `when`; a tie gives [SelectAmbiguous]. [evaluateWhen] evaluates the
  /// `when` predicates.
  SelectResult select(Tree<Json> node, {WhenEvaluator? evaluateWhen}) {
    final readCache = <String, ReadResult>{};
    final reasons = <String>[];

    // Pass 1: group the variants by rank, matching selectors only.
    final byTier = <_Rank, List<_Ranked>>{};
    for (var i = 0; i < variants.length; i++) {
      final variant = variants[i];
      final rank = _rank(variant);
      switch (variant.selector.match(node, readCache: readCache)) {
        case MatchSuccess():
          (byTier[rank] ??= []).add((
            variant: variant,
            index: i,
            selectorBlock: null,
          ));
        case MatchBlocked(:final query, :final blocker):
          (byTier[rank] ??= []).add((
            variant: variant,
            index: i,
            selectorBlock: SelectBlocked(query, blocker),
          ));
        case MatchFailure(:final reason):
          reasons.add('variant $i: $reason');
      }
    }

    // Pass 2: decide from the highest tier down.
    final tiers = byTier.keys.toList()..sort(_higherFirst);
    for (final tier in tiers) {
      final applies = <SelectMatch>[];
      SelectBlocked? blocked;
      for (final ranked in byTier[tier]!) {
        if (ranked.selectorBlock != null) {
          blocked ??= ranked.selectorBlock;
          continue;
        }
        final variant = ranked.variant;
        if (!variant.hasWhen) {
          applies.add(SelectMatch(variant, ranked.index));
          continue;
        }
        if (evaluateWhen == null) {
          throw StateError(
            'Rule "$key" has a variant with a "when" predicate but '
            'select() was called without a when evaluator; resolve via '
            'a Resolver.',
          );
        }
        switch (evaluateWhen(variant, node, ranked.index)) {
          case MatchSuccess():
            applies.add(SelectMatch(variant, ranked.index));
          case MatchFailure(:final reason):
            reasons.add('variant ${ranked.index}: $reason');
          case MatchBlocked(:final query, :final blocker):
            blocked ??= SelectBlocked(query, blocker);
        }
      }

      if (applies.length > 1) {
        return SelectAmbiguous(
          tier.conditions,
          applies,
          priority: tier.priority,
        );
      }
      // A blocked variant could still win: defer.
      if (blocked != null) return blocked;
      if (applies.length == 1) return applies.single;
    }

    return SelectNone(reasons);
  }

  // ...........................................................................
  /// Returns this rule with the variants of [other] appended.
  ///
  /// Throws on conflicting `optional` or `resultType` declarations.
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
  /// Serializes the rule to JSON, as a plain variant list when possible.
  Object toJson() {
    final variantsJson = variants.map((v) => v.toJson()).toList();
    if (optionalFlag == null && resultType == null) return variantsJson;
    return <String, dynamic>{
      if (optionalFlag != null) 'optional': optionalFlag,
      if (resultType != null) 'resultType': resultType!.jsonValue,
      'variants': variantsJson,
    };
  }

  // ...........................................................................
  /// The rank of [variant] in [select].
  static _Rank _rank(RuleVariant variant) => (
    conditions: variant.selector.specificity,
    priority: variant.priority,
    hasWhen: variant.hasWhen,
  );

  // ...........................................................................
  /// Sorts ranks highest first: conditions, then priority, then `when`.
  static int _higherFirst(_Rank a, _Rank b) {
    if (a.conditions != b.conditions) {
      return b.conditions.compareTo(a.conditions);
    }
    if (a.priority != b.priority) return b.priority.compareTo(a.priority);
    return (b.hasWhen ? 1 : 0).compareTo(a.hasWhen ? 1 : 0);
  }
}
