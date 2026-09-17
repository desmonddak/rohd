# Analyzer plugin cache reproduction

This reproduction starts from the ROHD `v0.6.10` release and adds one semantic
analysis-server plugin rule. The rule visits resolved class declarations,
accesses their resolved superclass, and never reports a diagnostic.

The benchmark compares:

1. `dart analyze` using its normal persistent analysis cache.
2. `dart analyze` using a newly created isolated cache over repeated passes.
3. `dart analyze` with the no-op semantic plugin over repeated, unchanged
   passes.

The plugin source is excluded from root analysis so the benchmark starts only
one plugin instance.

The captured benchmark uses Dart 3.11.6, the newest 3.11 stable release. It
does not invoke `dart format`, and all analyzer diagnostics remain fatal.
No existing lint configuration is changed: apart from the plugin registration
and exclusion of the plugin's own source, `analysis_options.yaml` is identical
to the `v0.6.10` file.

## Run

From the repository root:

```bash
tool/analyzer_plugin_cache_repro/run_benchmark.sh
```

Set `DART_BIN` to select an exact SDK:

```bash
DART_BIN=/path/to/dart-3.11.6/bin/dart \
  tool/analyzer_plugin_cache_repro/run_benchmark.sh
```

Pass an iteration count and output path if desired:

```bash
tool/analyzer_plugin_cache_repro/run_benchmark.sh \
  3 \
  tool/analyzer_plugin_cache_repro/results/local.txt
```

The script restores `analysis_options.yaml` and removes its temporary isolated
cache on exit.

## Captured result

The committed result in `results/dart-3.11.6-linux.txt` was captured on Linux
using Dart 3.11.6.

| Case | Pass 1 | Pass 2 | Pass 3 | Warm/unchanged average |
|---|---:|---:|---:|---:|
| Native analyzer, default persistent cache | 23.863s | 2.744s | 3.509s | 3.127s |
| Native analyzer, new isolated cache | 20.583s | 1.578s | 3.497s | 2.538s |
| No-op semantic plugin, unchanged source | 18.387s | 17.590s | 18.965s | 18.314s |

The first default-cache pass populated analysis data for the isolated Dart
3.11.6 SDK. The average shown for both native cases uses their subsequent
warm passes. The plugin bootstrap and AOT preparation took 135.401s and is
excluded from the comparison.

After preparation, the unchanged no-op plugin remained 5.9 times slower than
native analysis using its normal warmed cache. Both native cache cases warmed
after their first pass; the plugin did not.

The result isolates plugin-host behavior from rule complexity: the only rule
does not report diagnostics or perform a recursive traversal.

## Relevant upstream issues and change

- [dart-lang/sdk#63292](https://github.com/dart-lang/sdk/issues/63292) -
  `analysis_server_plugin` is extremely slow.
- [dart-lang/sdk#64202](https://github.com/dart-lang/sdk/issues/64202) -
  use a real/persistent `ByteStore` in analyzer plugins.
- [dart-lang/sdk#61490](https://github.com/dart-lang/sdk/issues/61490) -
  analyzer plugins run several times for the same analysis.
- [Dart SDK CL 543560](https://dart-review.googlesource.com/c/sdk/+/543560) -
  prototype persistent `FileByteStore` support for analyzer plugins.
