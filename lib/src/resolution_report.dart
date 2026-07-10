// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';

/// What produced a resolved value during a verbose resolve.
enum ProvenanceKind {
  /// A named rule variant.
  rule,

  /// An inline `§expression` map.
  inline,

  /// An optional rule that matched no variant and was removed.
  optionalRemoval,
}

// .............................................................................
/// What produced the value at a tree location, recorded by
/// [Resolver.resolveVerbose].
///
/// Minimal fields ([location], [kind], [ruleKey], [variantIndex],
/// [value]) are always present; rich fields ([selector], [inputs],
/// [expression], [aliasChain]) are set only when the resolve ran with
/// `rich: true`.
class ProvenanceEntry {
  /// Creates a provenance entry.
  const ProvenanceEntry({
    required this.location,
    required this.kind,
    this.ruleKey,
    this.variantIndex,
    this.value,
    this.selector,
    this.inputs,
    this.expression,
    this.aliasChain,
  });

  /// The tree location that was resolved, e.g. `'/dialog#borderWidth'`.
  final String location;

  /// What produced the value.
  final ProvenanceKind kind;

  /// The rule key that produced the value, or null for an inline
  /// expression.
  final String? ruleKey;

  /// The index of the winning variant in the merged rule, or null for
  /// inline expressions and optional removals.
  final int? variantIndex;

  /// The produced value. Null for an optional removal.
  final Object? value;

  /// Rich only: the winning variant's selector conditions (empty for a
  /// base variant); null otherwise.
  final Map<String, Object>? selector;

  /// Rich only: the inputs bound for the expression (name → value).
  final Map<String, Object?>? inputs;

  /// Rich only: the CEL expression source.
  final String? expression;

  /// Rich only: the rule keys applied at this location (length > 1 for
  /// aliases).
  final List<String>? aliasChain;

  // ...........................................................................
  /// A short one-line, human-readable description.
  @override
  String toString() {
    final source = switch (kind) {
      ProvenanceKind.rule => '$ruleKey[$variantIndex]',
      ProvenanceKind.inline => 'inline',
      ProvenanceKind.optionalRemoval => '$ruleKey (optional)',
    };
    final outcome = kind == ProvenanceKind.optionalRemoval
        ? 'removed'
        : '= $value';
    final detail = <String>[
      if (selector != null && selector!.isNotEmpty) 'selector $selector',
      if (inputs != null && inputs!.isNotEmpty) 'inputs $inputs',
      if (expression != null) 'expr "$expression"',
      if (aliasChain != null && aliasChain!.length > 1)
        'via ${aliasChain!.join(' → ')}',
    ];
    final suffix = detail.isEmpty ? '' : '  {${detail.join('; ')}}';
    return '$location ← $source $outcome$suffix';
  }

  /// JSON representation; rich fields are omitted when null.
  Json toJson() => {
    'location': location,
    'kind': kind.name,
    if (ruleKey != null) 'ruleKey': ruleKey,
    if (variantIndex != null) 'variantIndex': variantIndex,
    if (kind != ProvenanceKind.optionalRemoval) 'value': value,
    if (selector != null) 'selector': selector,
    if (inputs != null) 'inputs': inputs,
    if (expression != null) 'expression': expression,
    if (aliasChain != null) 'aliasChain': aliasChain,
  };
}

// .............................................................................
/// The provenance of every value produced by [Resolver.resolveVerbose].
///
/// Entries are in resolution order. A location appears more than once
/// when a rule alias resolved it in several hops (one entry per hop).
class ResolutionReport {
  /// Creates a report over [entries]. [rich] records whether the
  /// resolve captured the rich fields.
  ResolutionReport({required List<ProvenanceEntry> entries, this.rich = false})
    : entries = List.unmodifiable(entries);

  /// Every recorded value, in resolution order.
  final List<ProvenanceEntry> entries;

  /// Whether the rich fields were captured.
  final bool rich;

  /// The entries recorded at [location], in resolution order.
  Iterable<ProvenanceEntry> at(String location) =>
      entries.where((e) => e.location == location);

  /// A multi-line, human-readable dump.
  @override
  String toString() {
    final mode = rich ? 'rich' : 'minimal';
    return [
      'ResolutionReport (${entries.length} entries, $mode):',
      ...entries.map((e) => '  $e'),
    ].join('\n');
  }

  /// JSON representation.
  Json toJson() => {
    'rich': rich,
    'entries': [for (final e in entries) e.toJson()],
  };
}
