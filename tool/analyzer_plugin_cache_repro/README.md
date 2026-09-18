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

The captured benchmarks use Dart 3.11.6, the newest 3.11 stable release, and
Dart 3.13.0-167.1.beta and 3.14.0-211.1.beta. The benchmark does not invoke
`dart format`, and all analyzer diagnostics remain fatal. No existing lint
configuration is changed: apart from the plugin registration and exclusion of
the plugin's own source, `analysis_options.yaml` is identical to the `v0.6.10`
file.

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

The committed result in `results/dart-3.13.0-167.1.beta-linux.txt` was
captured on Linux using Dart 3.13.0-167.1.beta. The source changes required
for the beta's stricter lint set preserve all public constructor parameters and
their defaults.

| Case | Pass 1 | Pass 2 | Pass 3 | Warm/unchanged average |
|---|---:|---:|---:|---:|
| Native analyzer, default persistent cache | 3.008s | 1.045s | 1.254s | 1.150s |
| Native analyzer, new isolated cache | 10.665s | 1.247s | 1.417s | 1.332s |
| No-op semantic plugin, unchanged source | 18.738s | 20.897s | 18.941s | 19.525s |

The default persistent cache was already warm because the beta analyzer had
been run to validate the source updates before this capture. The first
isolated-cache pass populated its new cache. The plugin bootstrap and AOT
preparation took 27.915s and is excluded from the comparison.

After preparation, the unchanged no-op plugin was 17.0 times slower than
native analysis using its normal warmed cache. The beta improved native warm
analysis versus the 3.11.6 capture, but did not improve the plugin's unchanged
analysis time.

The committed result in `results/dart-3.14.0-211.1.beta-linux.txt` was
captured on Linux using Dart 3.14.0-211.1.beta.

| Case | Pass 1 | Pass 2 | Pass 3 | Warm/unchanged average |
|---|---:|---:|---:|---:|
| Native analyzer, default persistent cache | 2.955s | 1.603s | 1.380s | 1.492s |
| Native analyzer, new isolated cache | 12.253s | 0.930s | 1.664s | 1.297s |
| No-op semantic plugin, unchanged source | 96.659s | 699.455s | 113.929s | 303.348s |

The default persistent cache was already warm from prior validation. The first
isolated-cache pass populated its new cache. The plugin bootstrap and AOT
preparation took 103.760s and is excluded from the comparison.

After preparation, the unchanged no-op plugin was 203.4 times slower than
native analysis using its normal warmed cache. Its second unchanged pass took
699.455s despite using only 135.899 user CPU seconds. Two preceding full
benchmark attempts crashed with `Bus error (SIGBUS)` during plugin bootstrap,
but a standalone plugin-enabled analysis and the final full benchmark
completed successfully.

An independent rerun is captured in
`results/dart-3.14.0-211.1.beta-linux-rerun.txt`.

| Case | Pass 1 | Pass 2 | Pass 3 | Warm/unchanged average |
|---|---:|---:|---:|---:|
| Native analyzer, default persistent cache | 1.637s | 1.118s | 1.701s | 1.410s |
| Native analyzer, new isolated cache | 12.480s | 0.668s | 0.646s | 0.657s |
| No-op semantic plugin, unchanged source | 77.578s | 81.642s | 12.215s | 57.145s |

The rerun bootstrap and AOT preparation took 127.459s. Its plugin passes
ranged from 12.215s to 81.642s, while the first completed capture ranged from
96.659s to 699.455s. The six completed plugin passes therefore span
12.215s to 699.455s, confirming highly variable performance on this beta.

## Relevant upstream issues and change

- [dart-lang/sdk#63292](https://github.com/dart-lang/sdk/issues/63292) -
  `analysis_server_plugin` is extremely slow.
- [dart-lang/sdk#64202](https://github.com/dart-lang/sdk/issues/64202) -
  use a real/persistent `ByteStore` in analyzer plugins.
- [dart-lang/sdk#61490](https://github.com/dart-lang/sdk/issues/61490) -
  analyzer plugins run several times for the same analysis.
- [Dart SDK CL 543560](https://dart-review.googlesource.com/c/sdk/+/543560) -
  prototype persistent `FileByteStore` support for analyzer plugins.
