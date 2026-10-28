// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';
import 'package:analyzer/analysis_rule/analysis_rule.dart';

import 'package:rohd_analyzer_plugin/src/avoid_mutating_const_rule.dart';
import 'package:rohd_analyzer_plugin/src/non_port_public_hardware_fix.dart';
import 'package:rohd_analyzer_plugin/src/non_port_public_hardware_rule.dart';
import 'package:rohd_analyzer_plugin/src/ssa_read_before_write_rule.dart';

/// The ROHD analyzer plugin entry point.
final plugin = RohdAnalyzerPlugin();

/// Registers ROHD analyzer rules.
class RohdAnalyzerPlugin extends Plugin {
  @override
  String get name => 'ROHD analyzer';

  @override
  void register(PluginRegistry registry) {
    rohdWarningRules().forEach(registry.registerWarningRule);
    registry
      ..registerFixForRule(
        NonPortPublicHardwareRule.code,
        NonPortPublicHardwareFix.new,
      )
      ..registerFixForRule(
        NonPortPublicHardwareRule.code,
        NonPortPublicHardwareProtectedFix.new,
      )
      ..registerFixForRule(
        NonPortPublicHardwareRule.code,
        NonPortPublicHardwareInOutFix.new,
      )
      ..registerFixForRule(
        NonPortPublicHardwareRule.code,
        NonPortPublicHardwareInputFix.new,
      )
      ..registerFixForRule(
        NonPortPublicHardwareRule.code,
        NonPortPublicHardwareGeneratedListFix.new,
      )
      ..registerFixForRule(
        NonPortPublicHardwareRule.code,
        NonPortPublicHardwareLeafListFix.new,
      )
      ..registerFixForRule(
        NonPortPublicHardwareRule.code,
        NonPortPublicHardwareArrayFix.new,
      );
  }
}

/// Creates every warning rule registered by the ROHD analyzer plugin.
List<AnalysisRule> rohdWarningRules() => [
  NonPortPublicHardwareRule(),
  AvoidMutatingConstRule(),
  SsaReadBeforeWriteRule(),
];
