# rohd_analyzer_plugin

The ROHD analyzer plugin provides the same stable rule identities used by the
ROHD VS Code extension. It is supported by Dart 3.10 and later and reports
diagnostics through both the Dart Analysis Server and `dart analyze`.

Enable it from an application's top-level `analysis_options.yaml`:

```yaml
plugins:
  rohd_analyzer_plugin:
    path: ../rohd_analyzer_plugin
```

Rules:

- `rohd_hierarchy/non_port_public_hardware` (`ROHD-H001`) checks public
  hardware members for current-module port ownership. A Quick Fix is offered
  for a `late final Logic` field with exactly one constructor assignment when
  it can be safely converted into a registered output getter. For a field
  proven to be internal to a private class, the fix can instead add a
  `@protected` annotation and import. A conservatively recognized
  `List<Logic>` output-building pattern can be converted to a registered
  `LogicArray` using `addOutputArray`.
- `rohd_signals/avoid_mutating_const` (`ROHD-S001`) reports `inject` and `put`
  calls whose receiver is proven to be a ROHD `Const`. Its intraprocedural
  analysis follows straight-line local aliases and const-only list provenance,
  including lists populated with `add(Const(...))`. Unknown or mixed writes
  discard proof to avoid false positives.
- `rohd_signals/ssa_read_before_write` (`ROHD-S002`) reports direct reads of
  `s(signal)` before an earlier `s(signal) < value` assignment in an inline
  `Combinational.ssa` callback. The check is intentionally conservative: it
  follows direct SSA calls in callback statement order and does not attempt to
  prove arbitrary helper-method or control-flow behavior.

`ROHD-S002` is specific to `Combinational.ssa`. It does not replace ROHD's
runtime `WriteAfterReadException` check for ordinary `Combinational` blocks,
and the plugin does not register a separate regular-combinational
write-after-read lint.
## Adding a rule

1. Add the canonical ID, slug, analyzer name, severity, summary, and any shared
   metadata to `analyzer/rules/rohd_rules.yaml`.
2. From the repository root, regenerate the Dart registry:

   ```bash
   dart run tool/generate_rohd_rule_registry.dart
   dart format tool/generate_rohd_rule_registry.dart \
     packages/rohd_analyzer_plugin/lib
   ```

3. Implement an `AnalysisRule` under `lib/src/`, use resolved package, type,
   constructor, and method elements for semantic decisions, and add its factory
   to `rohdWarningRules()` in `lib/main.dart`.
4. Add analyzer fixtures and positive/negative tests under `test/`. Fixtures
   should define the smallest fake `package:rohd` API needed to prove resolved
   identity.
5. Validate from the repository root:

   ```bash
   dart run tool/generate_rohd_rule_registry.dart
   cd packages/rohd_analyzer_plugin
   dart test
   dart analyze
   ```
