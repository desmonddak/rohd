// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// The minimal analyzer plugin entry point.
final plugin = CacheReproductionPlugin();

/// Registers one semantic rule which never reports a diagnostic.
class CacheReproductionPlugin extends Plugin {
  @override
  String get name => 'ROHD analyzer cache reproduction';

  @override
  void register(PluginRegistry registry) {
    registry.registerWarningRule(NoOpSemanticRule());
  }
}

/// Visits resolved class declarations without reporting diagnostics.
class NoOpSemanticRule extends AnalysisRule {
  /// The unused diagnostic code required by [AnalysisRule].
  static const code = LintCode(
    'rohd_cache_repro/no_op_semantic_rule',
    'This diagnostic is never reported.',
  );

  /// Creates the no-op semantic rule.
  NoOpSemanticRule()
    : super(
        name: 'rohd_cache_repro/no_op_semantic_rule',
        description:
            'Visits resolved class declarations without reporting diagnostics.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addClassDeclaration(this, _ResolvedClassVisitor());
  }
}

class _ResolvedClassVisitor extends SimpleAstVisitor<void> {
  @override
  void visitClassDeclaration(ClassDeclaration node) {
    // Accessing the element ensures this remains a semantic, resolved rule.
    node.declaredFragment?.element.supertype;
  }
}
