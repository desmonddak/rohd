// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

import 'package:rohd_analyzer_plugin/src/rohd_rule_ids.dart';
import 'package:rohd_analyzer_plugin/src/rohd_semantics.dart';

/// Reports calls that try to mutate a value proven to be a ROHD `Const`.
class AvoidMutatingConstRule extends AnalysisRule {
  /// The diagnostic emitted for an invalid mutation.
  static const LintCode code = LintCode(
    avoidMutatingConstAnalyzerName,
    'A ROHD Const cannot be mutated with {0}.',
    correctionMessage:
        'Use a mutable Logic value, or avoid calling the mutation method.',
  );

  /// Creates the ROHD constant-mutation rule.
  AvoidMutatingConstRule()
    : super(
        name: avoidMutatingConstAnalyzerName,
        description: 'Prevents inject and put calls on ROHD Const values.',
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

class _Visitor extends SimpleAstVisitor<void> {
  final AvoidMutatingConstRule rule;

  _Visitor(this.rule);

  @override
  void visitCompilationUnit(CompilationUnit node) {
    for (final invocation in findConstMutationInvocations(node)) {
      rule.reportAtNode(
        invocation.methodName,
        arguments: [invocation.methodName.name],
      );
    }
  }
}

/// Finds invalid mutations using conservative, intraprocedural provenance.
///
/// The analysis follows straight-line local aliases and list identity. Proof is
/// discarded at control-flow boundaries and after unknown or mutable writes.
List<MethodInvocation> findConstMutationInvocations(CompilationUnit unit) {
  final collector = _ConstMutationCollector();
  unit.accept(collector);
  return collector.violations;
}

enum _ValueKind { rohdConst, mutable, unknown, constOnlyList }

class _Value {
  _ValueKind kind;

  _Value(this.kind);
}

class _ConstMutationCollector extends RecursiveAstVisitor<void> {
  static final _rohdConst = _Value(_ValueKind.rohdConst);
  static final _mutable = _Value(_ValueKind.mutable);
  static final _unknown = _Value(_ValueKind.unknown);

  final semantics = RohdSemantics();
  final values = <VariableElement, _Value>{};
  final violations = <MethodInvocation>[];

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    final previous = Map<VariableElement, _Value>.of(values);
    values.clear();
    node.visitChildren(this);
    values
      ..clear()
      ..addAll(previous);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    final previous = Map<VariableElement, _Value>.of(values);
    values.clear();
    node.visitChildren(this);
    values
      ..clear()
      ..addAll(previous);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final initializer = node.initializer;
    initializer?.accept(this);
    final element = node.declaredFragment?.element;
    if (element != null) {
      values[element] = initializer == null ? _unknown : _valueOf(initializer);
    }
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    node.rightHandSide.accept(this);
    final right = _valueOf(node.rightHandSide);
    switch (node.leftHandSide) {
      case final SimpleIdentifier identifier:
        final element = identifier.element;
        if (element is VariableElement) {
          values[element] = right;
        }
      case final IndexExpression index:
        final collection = _valueOf(index.realTarget);
        if (collection.kind == _ValueKind.constOnlyList &&
            right.kind != _ValueKind.rohdConst) {
          collection.kind = _ValueKind.unknown;
        }
      default:
        break;
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final receiver = node.realTarget;
    if (receiver != null &&
        semantics.isRohdLogicMutation(node) &&
        _valueOf(receiver).kind == _ValueKind.rohdConst) {
      violations.add(node);
    }

    receiver?.accept(this);
    for (final argument in node.argumentList.arguments) {
      argument.accept(this);
    }

    if (receiver != null) {
      final target = _valueOf(receiver);
      if (target.kind == _ValueKind.constOnlyList) {
        if (semantics.isCoreListMethod(node, const {'add'})) {
          if (_valueOf(node.argumentList.arguments.single).kind !=
              _ValueKind.rohdConst) {
            target.kind = _ValueKind.unknown;
          }
        } else if (semantics.isCoreListMethod(node, const {'addAll'})) {
          if (_valueOf(node.argumentList.arguments.single).kind !=
              _ValueKind.constOnlyList) {
            target.kind = _ValueKind.unknown;
          }
        } else {
          target.kind = _ValueKind.unknown;
        }
      }
    }

    for (final argument in node.argumentList.arguments) {
      final value = _valueOf(argument);
      if (value.kind == _ValueKind.constOnlyList) {
        value.kind = _ValueKind.unknown;
      }
    }
  }

  @override
  void visitIfStatement(IfStatement node) {
    values.clear();
    node.expression.accept(this);
    values.clear();
    node.thenStatement.accept(this);
    values.clear();
    node.elseStatement?.accept(this);
    values.clear();
  }

  @override
  void visitForStatement(ForStatement node) {
    values.clear();
    node.body.accept(this);
    values.clear();
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    values.clear();
    node.body.accept(this);
    values.clear();
  }

  @override
  void visitDoStatement(DoStatement node) {
    values.clear();
    node.body.accept(this);
    values.clear();
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    values.clear();
    for (final member in node.members) {
      values.clear();
      member.accept(this);
    }
    values.clear();
  }

  _Value _valueOf(Expression expression) {
    final unwrapped = switch (expression) {
      ParenthesizedExpression(:final expression) => expression,
      AsExpression(:final expression) => expression,
      PostfixExpression(:final operand, :final operator)
          when operator.lexeme == '!' =>
        operand,
      _ => expression,
    };
    if (!identical(unwrapped, expression)) {
      return _valueOf(unwrapped);
    }
    return switch (expression) {
      final InstanceCreationExpression creation
          when semantics.isRohdConstCreation(creation) =>
        _rohdConst,
      final SimpleIdentifier identifier => _identifierValue(identifier),
      final IndexExpression index => switch (_valueOf(index.realTarget).kind) {
        _ValueKind.constOnlyList => _rohdConst,
        _ValueKind.mutable => _mutable,
        _ => _unknown,
      },
      final ListLiteral literal => _listValue(
        literal.elements.whereType<Expression>(),
        literal.elements.length,
      ),
      final InstanceCreationExpression creation
          when _isCoreListGenerate(creation) =>
        _generatedListValue(creation.argumentList),
      final MethodInvocation invocation
          when semantics.isCoreListMethod(invocation, const {'generate'}) =>
        _generatedListValue(invocation.argumentList),
      final InstanceCreationExpression creation when _isRohdLogic(creation) =>
        _mutable,
      _ => _unknown,
    };
  }

  _Value _identifierValue(SimpleIdentifier identifier) {
    final element = identifier.element;
    return element is VariableElement ? values[element] ?? _unknown : _unknown;
  }

  static bool _isRohdLogic(InstanceCreationExpression creation) {
    final owner = creation.constructorName.element?.enclosingElement;
    return owner is ClassElement &&
        owner.name == 'Logic' &&
        owner.library.uri.toString().startsWith('package:rohd/');
  }

  static bool _isCoreListGenerate(InstanceCreationExpression creation) {
    final constructor = creation.constructorName.element;
    final owner = constructor?.enclosingElement;
    return constructor?.name == 'generate' &&
        owner is ClassElement &&
        owner.name == 'List' &&
        owner.library.uri.toString() == 'dart:core';
  }

  _Value _listValue(Iterable<Expression> expressions, int elementCount) {
    final values = expressions.map(_valueOf).toList();
    return values.length == elementCount &&
            values.every((value) => value.kind == _ValueKind.rohdConst)
        ? _Value(_ValueKind.constOnlyList)
        : _unknown;
  }

  _Value _generatedListValue(ArgumentList arguments) {
    if (arguments.arguments.length < 2) {
      return _unknown;
    }
    final generator = arguments.arguments[1];
    final expression =
        generator is FunctionExpression &&
            generator.body is ExpressionFunctionBody
        ? (generator.body as ExpressionFunctionBody).expression
        : null;
    return expression != null &&
            _valueOf(expression).kind == _ValueKind.rohdConst
        ? _Value(_ValueKind.constOnlyList)
        : _unknown;
  }
}
