// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:math';

/// Returns the [candidates] most similar to [input], best match first.
///
/// Candidates further away than [maxDistance] edits are dropped; at
/// most [maxSuggestions] are returned. Used to enrich unknown-rule
/// errors with "did you mean" hints.
List<String> didYouMean(
  String input,
  Iterable<String> candidates, {
  int maxDistance = 3,
  int maxSuggestions = 3,
}) {
  final scored = <(String, int)>[];
  for (final candidate in candidates) {
    final distance = levenshtein(input, candidate);
    if (distance <= maxDistance) {
      scored.add((candidate, distance));
    }
  }
  scored.sort((a, b) => a.$2.compareTo(b.$2));
  return scored.take(maxSuggestions).map((e) => e.$1).toList();
}

/// Returns the Levenshtein edit distance between [a] and [b].
int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);

  for (var i = 0; i < a.length; i++) {
    current[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      final substitution = previous[j] + (a[i] == b[j] ? 0 : 1);
      current[j + 1] = min(
        substitution,
        min(previous[j + 1] + 1, current[j] + 1),
      );
    }
    final swap = previous;
    previous = current;
    current = swap;
  }

  return previous[b.length];
}
