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
import 'tree_reader.dart';

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

/// Two or more variants match at the same (winning) specificity, so the
/// winner is ambiguous. Ties are never broken silently — the author
/// must make the selectors specific enough that exactly one wins.
class SelectAmbiguous extends SelectResult {
  /// Creates the result carrying the shared [specificity] and the tied
  /// [matches], in rule order.
  const SelectAmbiguous(this.specificity, this.matches);

  /// The shared selector-condition count of the tied variants (their
  /// `when` predicates, if any, are also identical in presence).
  final int specificity;

  /// The tied matching variants, in rule order.
  final List<SelectMatch> matches;
}

// .............................................................................
/// Evaluates a variant's [RuleVariant.when] predicate at a node during
/// selection: [MatchSuccess] (holds), [MatchFailure] (does not), or
/// [MatchBlocked] (an input reads a still-unresolved value). Injected by
/// the resolver so [Rule.select] needs no CEL dependency of its own.
typedef WhenEvaluator =
    MatchResult Function(RuleVariant variant, Tree<Json> node, int index);

/// A selector-matching (or selector-blocked) variant kept during
/// [Rule.select], grouped by effective specificity. `selectorBlock` is
/// non-null when the selector itself is blocked (deferred).
typedef _Ranked = ({
  RuleVariant variant,
  int index,
  SelectBlocked? selectorBlock,
});

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

  /// An example rule computing a border width: a base variant, a
  /// dark-mode override, and the [RuleVariant.example] refinement.
  factory Rule.example() => Rule(
    key: 'borderWidth',
    variants: [
      RuleVariant(expression: '1.0'),
      RuleVariant(selector: Selector({'theme#id': 'dark'}), expression: '2.0'),
      RuleVariant.example(),
    ],
    resultType: ResultType.number,
  );

  /// The rule key (a plain identifier, no `§` prefix).
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
  /// A variant applies when its selector matches and its [
  /// RuleVariant.when] predicate (if any) holds. The applying variant
  /// with the highest **effective specificity** wins:
  /// `2 * selectorConditions + (when != null ? 1 : 0)` — i.e. more
  /// selector conditions win outright, and a `when` breaks ties among
  /// variants with the same condition count (so a `when`-variant beats
  /// the otherwise-identical one, including the base).
  ///
  /// If two or more variants apply at that same effective specificity
  /// the result is [SelectAmbiguous]: ties are an error, not broken by
  /// order. Returns [SelectBlocked] when a blocked variant could still
  /// change the outcome once resolved.
  ///
  /// Selection walks tiers from the highest effective specificity down,
  /// so a `when` is evaluated only for the tier that can still win — a
  /// dominated variant's `when` (including a broken one) is never run
  /// and cannot abort resolution.
  ///
  /// [evaluateWhen] evaluates `when` predicates; the resolver supplies
  /// it. It may be omitted only when no reachable variant has a `when`.
  SelectResult select(Tree<Json> node, {WhenEvaluator? evaluateWhen}) {
    final readCache = <String, ReadResult>{};
    final reasons = <String>[];

    // Pass 1: match selectors only (cheap, never throws). Group the
    // selector-matching and selector-blocked variants by effective
    // specificity.
    final byTier = <int, List<_Ranked>>{};
    for (var i = 0; i < variants.length; i++) {
      final variant = variants[i];
      final spec = _effectiveSpecificity(variant);
      switch (variant.selector.match(node, readCache: readCache)) {
        case MatchSuccess():
          (byTier[spec] ??= []).add((
            variant: variant,
            index: i,
            selectorBlock: null,
          ));
        case MatchBlocked(:final query, :final blocker):
          (byTier[spec] ??= []).add((
            variant: variant,
            index: i,
            selectorBlock: SelectBlocked(query, blocker),
          ));
        case MatchFailure(:final reason):
          reasons.add('variant $i: $reason');
      }
    }

    // Pass 2: decide from the highest tier down, evaluating `when` only
    // within the tier under consideration.
    final tiers = byTier.keys.toList()..sort((a, b) => b.compareTo(a));
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

      // Two or more apply at this tier → ambiguous (a pending block
      // can't un-ambiguate it, so decide now instead of deferring).
      if (applies.length > 1) {
        final spec = applies.first.variant.selector.specificity;
        return SelectAmbiguous(spec, applies);
      }
      // A block at this tier could still apply once resolved, so the
      // tier isn't final yet — defer.
      if (blocked != null) return blocked;
      if (applies.length == 1) return applies.single;
      // Tier produced no applying variant → descend.
    }

    return SelectNone(reasons);
  }

  /// `2 * selectorConditions + (when ? 1 : 0)` — a `when` ranks a
  /// variant just above an otherwise-identical one, while extra
  /// selector conditions always win outright.
  static int _effectiveSpecificity(RuleVariant variant) =>
      2 * variant.selector.specificity + (variant.hasWhen ? 1 : 0);

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
