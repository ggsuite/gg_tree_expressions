# Changelog

## [0.2.0] - 2026-07-09

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

[0.2.0]: https://github.com/ggsuite/gg_tree_expressions/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/ggsuite/gg_tree_expressions/compare/0.0.2...0.1.0
[0.0.2]: https://github.com/ggsuite/gg_tree_expressions/releases/tag/0.0.2
