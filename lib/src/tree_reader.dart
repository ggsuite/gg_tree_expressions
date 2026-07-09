// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';

import 'rule_ref.dart';
import 'tree_expressions_exception.dart';

// .............................................................................
/// The outcome of a marker-aware query read.
sealed class ReadResult {
  const ReadResult();
}

/// The query resolved to a value free of unresolved markers.
class ReadValue extends ReadResult {
  /// Creates the result carrying the resolved [value].
  const ReadValue(this.value);

  /// The value the query resolved to. Never null.
  final Object value;
}

/// The query resolved to nothing.
class ReadMissing extends ReadResult {
  /// Creates the result.
  const ReadMissing();
}

/// The query touches a still-unresolved value and must be retried
/// after further resolution.
class ReadBlocked extends ReadResult {
  /// Creates the result naming the [blocker] location.
  const ReadBlocked(this.blocker);

  /// The location of the unresolved value, e.g. `'/dialog#width'`.
  final String blocker;
}

// .............................................................................
/// Validates that [query] is parseable; throws with [context] if not.
void validateQuery(String query, {required String context}) {
  try {
    TreeQuery(query);
  } catch (e) {
    throw SchemaException([
      'Invalid query "$query" in $context:',
      messageOf(e),
    ]);
  }
}

/// Returns the message of [error] without the `'Exception: '` prefix.
String messageOf(Object error) {
  final text = error.toString();
  const prefix = 'Exception: ';
  return text.startsWith(prefix) ? text.substring(prefix.length) : text;
}

// .............................................................................
/// A query parsed once: its [TreeQuery] and the parsed data-path
/// [segments]. Both are pure functions of the query string, and a rule
/// book uses a small stable set of query strings, so parsing is cached.
class _ParsedQuery {
  _ParsedQuery(this.query, this.segments);
  final TreeQuery query;
  final List<String> segments;
}

final Map<String, _ParsedQuery> _parseCache = <String, _ParsedQuery>{};

/// Parses [query] once and caches the result by query string. Throws
/// (without caching) when the query is malformed. Bounded like
/// gg_tree's own query cache so a long-lived process cannot grow it
/// without limit.
_ParsedQuery _parse(String query) {
  final cached = _parseCache[query];
  if (cached != null) return cached;

  final parsed = TreeQuery(query);
  final result = _ParsedQuery(parsed, parseJsonPath(parsed.data));
  if (_parseCache.length >= 512) _parseCache.clear();
  _parseCache[query] = result;
  return result;
}

// .............................................................................
/// Reads [query] relative to [node], detecting unresolved markers.
///
/// Mirrors `Tree.getOrNull` semantics but returns [ReadBlocked] when
/// the resolution would read — or silently search past — a reference
/// string, escaped literal, or inline expression map. Shape errors
/// (e.g. a data path traversing a non-map value) throw a
/// [TreeExpressionsException] naming query and node.
ReadResult readQuery(Tree<Json> node, String query) {
  final _ParsedQuery pq;
  try {
    pq = _parse(query);
  } catch (e) {
    throw QueryException(
      ['Invalid query "$query" at node "${node.path}":', messageOf(e)],
      query: query,
      nodePath: node.path,
    );
  }
  final parsed = pq.query;

  // The '#node/...' namespace reads computed tree properties that live
  // outside node data and can never hold markers — the marker scan
  // cannot produce them, so read them the plain way.
  if (parsed.data.startsWith('${Tree.nodeInfoKey}/')) {
    return _realRead(node, query);
  }

  // Single walk: the scan mirrors getOrNull's search and returns the
  // value itself, so no second read of the same chain is needed. It
  // defers to the real read only for shape anomalies (rare), which
  // preserves getOrNull's exact error/edge semantics there.
  return _scanRead(node, parsed, pq.segments) ?? _realRead(node, query);
}

// .............................................................................
/// The plain gg_tree read. Used for the `#node/...` tree-info namespace
/// and as the fallback when the marker scan hits a shape anomaly. Wraps
/// engine errors as [QueryException].
ReadResult _realRead(Tree<Json> node, String query) {
  final Object? value;
  try {
    value = node.getOrNull<dynamic>(query);
  } catch (e) {
    throw QueryException(
      ['Query "$query" failed at node "${node.path}":', messageOf(e)],
      query: query,
      nodePath: node.path,
    );
  }

  if (value == null) return const ReadMissing();

  // Defensive: tree-info values and shape-anomaly fallbacks never hold
  // markers. Kept as a guard against future gg_tree semantic changes.
  if (containsMarker(value)) {
    // coverage:ignore-start
    return ReadBlocked('${node.path}#<result of "$query">');
    // coverage:ignore-end
  }
  return ReadValue(value);
}

// .............................................................................
/// Walks the same search chain as `Tree.getOrNull` and returns the read
/// result directly: the resolved value when the search lands on a
/// marker-free value, [ReadBlocked] when it would read or search past a
/// marker, [ReadMissing] when nothing is found, or `null` for a shape
/// anomaly (the caller defers those to the real read).
ReadResult? _scanRead(
  Tree<Json> node,
  TreeQuery parsed,
  List<String> segments,
) {
  final Iterable<Tree<Json>> searchNodes = parsed.searchToRoot
      ? node.ancestors(includeSelf: true)
      : <Tree<Json>>[node];

  for (final searchNode in searchNodes) {
    final target = searchNode.childByPathOrNull(parsed.node);
    if (target == null) continue;

    final (verdict, prefix, value) = _scanData(target, segments);
    switch (verdict) {
      case _Verdict.blocked:
        return ReadBlocked('${target.path}#$prefix');
      case _Verdict.clean:
        // Value found here (marker-free); markers above are shadowed.
        return ReadValue(value as Object);
      case _Verdict.aborted:
        // Shape anomaly — defer the whole read to getOrNull, which
        // resolves or throws exactly as before.
        return null;
      case _Verdict.missing:
        continue;
    }
  }
  return const ReadMissing();
}

// .............................................................................
enum _Verdict { clean, missing, blocked, aborted }

/// Walks [target]'s data along [segments]; reports markers on the
/// path or in the final value, and carries the resolved value on a
/// clean read. The root data map itself is never a marker.
(_Verdict, String, Object?) _scanData(
  Tree<Json> target,
  List<String> segments,
) {
  Object? cur = target.data;
  final walked = <String>[];
  var isRoot = true;

  for (final segment in segments) {
    if (cur == null) return (_Verdict.missing, '', null);
    if (!isRoot && isMarker(cur)) {
      return (_Verdict.blocked, walked.join('/'), null);
    }
    if (cur is! Map) return (_Verdict.aborted, '', null);
    isRoot = false;

    final String key;
    final Iterable<int> indices;
    try {
      (key, indices) = parseArrayIndex(segment);
    } catch (_) {
      return (_Verdict.aborted, '', null);
    }

    cur = cur[key];
    walked.add(key);

    for (final index in indices) {
      if (cur == null) break;
      // The marker sits at the path walked so far — before this
      // index is applied.
      if (isMarker(cur)) {
        return (_Verdict.blocked, walked.join('/'), null);
      }
      if (cur is! List) return (_Verdict.aborted, '', null);
      cur = index < cur.length ? cur[index] : null;
      walked.last = '${walked.last}[$index]';
    }
  }

  final prefix = walked.join('/');
  if (cur == null) return (_Verdict.missing, '', null);
  if (containsMarker(cur)) return (_Verdict.blocked, prefix, null);
  return (_Verdict.clean, prefix, cur);
}
