# Changelog

## [1.0.0] - 2026-07-10

### Added

- Add resolveAtomic for atomic in-place resolution

## [0.3.0] - 2026-07-10

### Changed

- Verbose mode

## [0.2.0] - 2026-07-09

### Added

- `Resolver` accepts an optional `expressionCache` so resolvers built
per fit/article share compiled expressions instead of re-parsing the
rule book each time (warm construction \~99% cheaper).
- Benchmark harness under `benchmark/` (six workload profiles, JIT and
AOT) with baselines and attribution in `benchmark/RESULTS.md`.

### Changed

- Performance: `readQuery` walks the search chain once — the marker
scan is now the engine of record and returns the value directly
instead of re-reading via `Tree.getOrNull`, also dropping a
redundant deep marker check. Added a per-`select()` read cache and a
bounded parsed-query cache. Large read-path and end-to-end speedups
with no behavior change.

## [0.1.0] - 2026-07-08

### Added

- Rule data model: `RuleBook` (JSON round-trip, merge with ascending
priority, lint, did-you-mean suggestions), `Rule` (variants,
CSS-like specificity, optional flag, result types), `RuleVariant`,
`RuleInput`, `Selector`.
- `CompiledExpression`: compile-once CEL wrapper reporting syntax
errors at compile time (with line and column), JSON-safe input
binding, and concise error mapping.
- `Resolver`: one `resolve()` call replaces every reference
(`{"§": "§rule"}`) and inline `§expression` map — worklist with
deferral, rule aliasing with cycle detection, optional rules,
result-type validation, and stuck diagnostics naming every pending
item. Strings are never references, so resolved trees stay
re-resolvable without escaping rules.
- Sealed exception hierarchy with typed fields
(`UnknownRuleException`, `CircularAliasException`, ...).
- Property-based test layer: a readQuery-vs-gg\_tree conformance
corpus and resolver invariants (marker-free, idempotent,
order-independent) over random trees and rule books.
- CEL conformance fixtures (`test/fixtures/cel_conformance.json`)
pinning the supported cross-language subset.

### Changed

- Correct version in pubspec for publish
- Correct version in changelog for publish
- Correct version in changelog for publish again

## [0.0.2] - 2026-06-30

### Added

- Initial boilerplate.

[1.0.0]: https://github.com/ggsuite/gg_tree_expressions/compare/0.3.0...1.0.0
[0.3.0]: https://github.com/ggsuite/gg_tree_expressions/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/ggsuite/gg_tree_expressions/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/ggsuite/gg_tree_expressions/compare/0.0.2...0.1.0
[0.0.2]: https://github.com/ggsuite/gg_tree_expressions/releases/tag/0.0.2
