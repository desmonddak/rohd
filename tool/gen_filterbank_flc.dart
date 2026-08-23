// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// gen_filterbank_flc.dart
// Regenerates FilterBank.flc.json and FilterBank.traced.flc.json
// asset files for the schematic viewer.
//
// Usage:
//   dart run tool/gen_filterbank_flc.dart
//
// The script builds a FilterBank module with signal-source tracing
// enabled, then writes FLC sidecar files via TraceService.
//
// 2026 May 6
// Author: Desmond A. Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:io';

import 'package:rohd/rohd.dart';

import '../example/filter_bank/filter_bank_modules.dart';

Future<void> main() async {
  const assetsDir = 'rohd_devtools_extension/rohd-schematic-viewer/assets';

  // Enable source tracing BEFORE building the module.
  SourceTracer.activate();

  const dataWidth = 16;
  const numTaps = 3;
  const coeffs0 = [1, 2, 1];
  const coeffs1 = [1, -2, 1];

  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final start = Logic(name: 'start');
  final samples = List.generate(2, (ch) => FilterSample(name: 'sample$ch'));
  final inputDone = Logic(name: 'inputDone');

  final dut = FilterBank(
    clk,
    reset,
    start,
    samples,
    inputDone,
    numTaps: numTaps,
    dataWidth: dataWidth,
    coefficients: [coeffs0, coeffs1],
  );

  await dut.build();

  // Both FLC files use TraceService (with SystemVerilogService line maps) so
  // that every signal gets `sv` entries for SV cross-probing.
  final sv = SystemVerilogService(dut, register: false);
  TraceService(dut, svService: sv, register: false)
      // Write the primary FLC (matches FilterBank.rohd.json sidecar).
      .write(assetsDir);
  stdout.writeln('Wrote $assetsDir/FilterBank.flc.json');

  // Write the traced variant (matches FilterBank.traced.rohd.json sidecar).
  File('$assetsDir/FilterBank.flc.json')
      .copySync('$assetsDir/FilterBank.traced.flc.json');
  stdout.writeln('Wrote $assetsDir/FilterBank.traced.flc.json');

  // Clean up the simulator.
  await Simulator.reset();
  stdout.writeln('Done.');
}
