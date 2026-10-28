// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// ssa_read_before_write_rule.dart
// Analyzer rule for detecting direct SSA reads before initialization.
//
// 2026 September
// Author: ROHD contributors

import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

import 'package:rohd_analyzer_plugin/src/rohd_rule_ids.dart';
import 'package:rohd_analyzer_plugin/src/rohd_semantics.dart';

/// Reports direct SSA reads that occur before their first assignment.
class SsaReadBeforeWriteRule extends AnalysisRule {
  /// The diagnostic emitted for an SSA read before initialization.
  static const LintCode code = LintCode(
    ssaReadBeforeWriteAnalyzerName,
    'SSA signal may be read before it is initialized.',
    correctionMessage:
        'Assign the signal through s(...) before reading it in this '
        'Combinational.ssa block.',
  );

  /// Creates the SSA initialization rule.
  SsaReadBeforeWriteRule()
    : super(
        name: ssaReadBeforeWriteAnalyzerName,
        description:
            'Checks direct Combinational.ssa reads for initialization.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addCompilationUnit(this, _Visitor(this));
  }
}

class _Visitor extends RecursiveAstVisitor<void> {
  final SsaReadBeforeWriteRule rule;
  final semantics = RohdSemantics();

  _Visitor(this.rule);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (semantics.isCombinationalSsa(node)) {
      FunctionExpression? callback;
      for (final argument in node.argumentList.arguments) {
        if (argument is FunctionExpression) {
          callback = argument;
          break;
        }
      }
      if (callback != null) {
        findSsaReadBeforeWriteInvocationsInCallback(
          callback,
        ).forEach(rule.reportAtNode);
      }
    }
    super.visitMethodInvocation(node);
  }
}

/// Finds direct SSA reads that occur before their first assignment.
List<AstNode> findSsaReadBeforeWriteInvocations(CompilationUnit unit) {
  final invocations = <AstNode>[];
  unit.accept(
    _InvocationCollector(
      (callback) => invocations.addAll(
        findSsaReadBeforeWriteInvocationsInCallback(callback),
      ),
    ),
  );
  return invocations;
}

/// Finds uninitialized reads within one `Combinational.ssa` callback.
List<AstNode> findSsaReadBeforeWriteInvocationsInCallback(
  FunctionExpression callback,
) {
  final analyzer = _SsaCallbackVisitor()..analyze(callback);
  return analyzer.violations;
}

class _InvocationCollector extends RecursiveAstVisitor<void> {
  final void Function(FunctionExpression callback) onCallback;
  final semantics = RohdSemantics();

  _InvocationCollector(this.onCallback);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (semantics.isCombinationalSsa(node)) {
      for (final argument in node.argumentList.arguments) {
        if (argument is FunctionExpression) {
          onCallback(argument);
          break;
        }
      }
    }
    super.visitMethodInvocation(node);
  }
}

class _SsaCallbackVisitor {
  final initialized = <VariableElement>{};
  final violations = <AstNode>[];
  final semantics = RohdSemantics();
  String? sParameter;

  void analyze(FunctionExpression callback) {
    final parameters = callback.parameters?.parameters;
    if (parameters != null && parameters.isNotEmpty) {
      sParameter = parameters.first.name?.lexeme;
    }
    final body = callback.body;
    if (body is ExpressionFunctionBody) {
      _analyzeExpression(body.expression);
    } else if (body is BlockFunctionBody) {
      body.block.accept(_BodyVisitor(this));
    }
  }

  void _analyzeExpression(Expression expression) {
    if (expression is ListLiteral) {
      expression.elements.whereType<Expression>().forEach(_analyzeExpression);
      return;
    }
    if (expression is BinaryExpression && expression.operator.lexeme == '<') {
      final argument = _ssaArgument(expression.leftOperand);
      final variable = _hardwareVariable(argument);
      if (variable != null) {
        _analyzeRead(expression.rightOperand);
        initialized.add(variable);
      } else {
        _analyzeRead(expression.leftOperand);
        _analyzeRead(expression.rightOperand);
      }
      return;
    }
    _analyzeRead(expression);
  }

  void _analyzeRead(Expression expression) {
    expression.accept(_ReadVisitor(this));
  }

  void reportRead(AstNode call, Expression argument) {
    final variable = _hardwareVariable(argument);
    if (variable != null && !initialized.contains(variable)) {
      violations.add(call);
    }
  }

  VariableElement? _hardwareVariable(Expression? expression) {
    final identifier = expression is SimpleIdentifier ? expression : null;
    final element = identifier?.element;
    return element is VariableElement && semantics.isHardwareType(element.type)
        ? element
        : null;
  }

  Expression? _ssaArgument(Expression expression) {
    if (expression is FunctionExpressionInvocation &&
        expression.argumentList.arguments.length == 1 &&
        expression.function is SimpleIdentifier &&
        (expression.function as SimpleIdentifier).name == sParameter) {
      return expression.argumentList.arguments.first;
    }
    return null;
  }
}

class _BodyVisitor extends RecursiveAstVisitor<void> {
  final _SsaCallbackVisitor analyzer;

  _BodyVisitor(this.analyzer);

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    analyzer._analyzeExpression(node.expression);
  }
}

class _ReadVisitor extends RecursiveAstVisitor<void> {
  final _SsaCallbackVisitor analyzer;

  _ReadVisitor(this.analyzer);

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final argument = analyzer._ssaArgument(node);
    if (argument != null) {
      analyzer.reportRead(node, argument);
    }
    super.visitFunctionExpressionInvocation(node);
  }
}
