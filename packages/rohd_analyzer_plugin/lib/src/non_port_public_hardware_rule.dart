// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import 'package:rohd_analyzer_plugin/src/rohd_rule_ids.dart';
import 'package:rohd_analyzer_plugin/src/rohd_semantics.dart';

/// Reports public hardware members that do not resolve to a local port.
class NonPortPublicHardwareRule extends AnalysisRule {
  /// Diagnostic code shared with the ROHD VS Code implementation.
  static const LintCode code = LintCode(
    nonPortPublicHardwareAnalyzerName,
    'Public hardware member is not backed by a port owned by this module.',
    correctionMessage:
        'Expose the signal through a local addInput/addOutput/addInterface '
        'routine, or make the member private or @protected.',
  );

  /// Creates the ROHD non-port public hardware rule.
  NonPortPublicHardwareRule()
    : super(
        name: nonPortPublicHardwareAnalyzerName,
        description:
            'Checks public hardware members for local ROHD port ownership.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addClassDeclaration(this, _Visitor(this, context));
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  final NonPortPublicHardwareRule rule;
  final RuleContext context;
  final semantics = RohdSemantics();

  _Visitor(this.rule, this.context);

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final element = node.declaredFragment?.element;
    if (element == null || !semantics.isModuleClass(element)) {
      return;
    }

    if (node.body is! BlockClassBody) {
      return;
    }
    final members = (node.body as BlockClassBody).members;
    final localFields = <String, FieldDeclaration>{};
    for (final member in members) {
      if (member is FieldDeclaration) {
        for (final variable in member.fields.variables) {
          localFields[variable.name.lexeme] = member;
        }
      }
    }
    final assignments = <String, List<Expression>>{};
    node
      ..accept(_AssignmentVisitor(assignments))
      ..accept(_ListPortExposureVisitor(assignments, semantics));
    final getterExpressions = <String, List<Expression>>{};
    for (final member in members) {
      if (member case final MethodDeclaration getter
          when getter.isGetter && getter.name.lexeme.isNotEmpty) {
        final expressions = <Expression>[
          if (getter.body case final ExpressionFunctionBody body)
            body.expression,
          if (getter.body case final BlockFunctionBody body)
            for (final statement in body.block.statements)
              if (statement case final ReturnStatement returnStatement
                  when returnStatement.expression != null)
                returnStatement.expression!,
        ];
        if (expressions.isNotEmpty) {
          getterExpressions[getter.name.lexeme] = expressions;
        }
      }
    }
    final localPortResolver = _LocalPortResolver(
      semantics,
      localFields,
      assignments,
      getterExpressions,
    );

    for (final member in members) {
      if (member is FieldDeclaration) {
        _checkFields(member, localPortResolver);
      } else if (member is MethodDeclaration && member.isGetter) {
        _checkGetter(member, localPortResolver);
      }
    }
  }

  void _checkFields(
    FieldDeclaration declaration,
    _LocalPortResolver localPortResolver,
  ) {
    if (declaration.isStatic ||
        _isIntentionallyInternal(declaration.metadata) ||
        declaration.fields.variables.every(
          (variable) => !semantics.isHardwareType(
            variable.declaredFragment?.element.type,
          ),
        )) {
      return;
    }

    for (final variable in declaration.fields.variables) {
      if (variable.name.lexeme.startsWith('_')) {
        continue;
      }
      if (!localPortResolver.hasLocalPortForName(variable.name.lexeme)) {
        rule.reportAtNode(variable);
      }
    }
  }

  void _checkGetter(
    MethodDeclaration getter,
    _LocalPortResolver localPortResolver,
  ) {
    if (getter.isStatic ||
        getter.name.lexeme.startsWith('_') ||
        _isIntentionallyInternal(getter.metadata) ||
        !semantics.isHardwareType(
          getter.declaredFragment?.element.returnType,
        )) {
      return;
    }

    final expressions = <Expression>[
      if (getter.body case final ExpressionFunctionBody body) body.expression,
      if (getter.body case final BlockFunctionBody body)
        for (final statement in body.block.statements)
          if (statement case final ReturnStatement returnStatement)
            returnStatement.expression!,
    ];
    if (expressions.isNotEmpty &&
        !localPortResolver.hasLocalPortExpression(expressions)) {
      rule.reportAtNode(getter);
    }
  }
}

class _LocalPortResolver {
  final RohdSemantics semantics;
  final Map<String, FieldDeclaration> localFields;
  final Map<String, List<Expression>> assignments;
  final Map<String, List<Expression>> getterExpressions;
  final Map<String, bool> _resolvedNames = {};
  final Map<Expression, bool> _directResults = Map.identity();

  _LocalPortResolver(
    this.semantics,
    this.localFields,
    this.assignments,
    this.getterExpressions,
  );

  bool hasLocalPortForName(String name) => _identifierResolvesToLocalPort(name);

  bool hasLocalPortExpression(Iterable<Expression> expressions) {
    for (final expression in expressions) {
      if (_isDirectLocalPortExpression(expression)) {
        return true;
      }
      final rootIdentifier = _rootIdentifier(expression);
      if (rootIdentifier != null &&
          _identifierResolvesToLocalPort(rootIdentifier.name)) {
        return true;
      }
    }
    return false;
  }

  SimpleIdentifier? _rootIdentifier(Expression expression) {
    if (expression is SimpleIdentifier) {
      return expression;
    }
    if (expression is ParenthesizedExpression) {
      return _rootIdentifier(expression.expression);
    }
    if (expression is PostfixExpression) {
      return _rootIdentifier(expression.operand);
    }
    if (expression is PrefixedIdentifier) {
      return expression.prefix;
    }
    if (expression is PropertyAccess) {
      final target = expression.target;
      if (target != null) {
        return _rootIdentifier(target);
      }
    }
    if (expression is IndexExpression) {
      final target = expression.target;
      if (target != null) {
        return _rootIdentifier(target);
      }
    }
    return null;
  }

  bool _identifierResolvesToLocalPort(String startName) {
    final cached = _resolvedNames[startName];
    if (cached != null) {
      return cached;
    }

    final pending = [startName];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final name = pending.removeLast();
      if (!visited.add(name)) {
        continue;
      }

      for (final expression in _sourceExpressions(name)) {
        if (_isDirectLocalPortExpression(expression)) {
          _resolvedNames[startName] = true;
          return true;
        }
        if (expression is SimpleIdentifier &&
            !visited.contains(expression.name)) {
          pending.add(expression.name);
        }
      }
    }

    _resolvedNames[startName] = false;
    return false;
  }

  Iterable<Expression> _sourceExpressions(String name) sync* {
    yield* assignments[name] ?? const <Expression>[];
    yield* getterExpressions[name] ?? const <Expression>[];

    final field = localFields[name];
    for (final variable in field?.fields.variables ?? <VariableDeclaration>[]) {
      if (variable.name.lexeme == name && variable.initializer != null) {
        yield variable.initializer!;
        return;
      }
    }
  }

  bool _isDirectLocalPortExpression(Expression expression) =>
      _directResults.putIfAbsent(expression, () {
        var foundFactory = false;
        expression.accept(
          _FactoryVisitor(
            semantics: semantics,
            onLocalFactory: () => foundFactory = true,
          ),
        );
        return foundFactory ||
            _isConstantHardwareExpression(expression) ||
            expression is NullLiteral;
      });

  bool _isConstantHardwareExpression(Expression expression) {
    if (expression is ParenthesizedExpression) {
      return _isConstantHardwareExpression(expression.expression);
    }
    if (expression is InstanceCreationExpression) {
      return semantics.isRohdConstCreation(expression);
    }
    if (expression is MethodInvocation &&
        expression.methodName.name == 'named' &&
        expression.target != null) {
      final target = expression.target!;
      return _isConstantHardwareExpression(target) ||
          (target is SimpleIdentifier &&
              _identifierResolvesToLocalPort(target.name));
    }
    if (expression is BinaryExpression) {
      return _isConstantHardwareExpression(expression.leftOperand) &&
          _isConstantHardwareExpression(expression.rightOperand);
    }
    if (expression is PrefixExpression) {
      return _isConstantHardwareExpression(expression.operand);
    }
    return false;
  }
}

class _AssignmentVisitor extends RecursiveAstVisitor<void> {
  final Map<String, List<Expression>> assignments;

  _AssignmentVisitor(this.assignments);

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final name = switch (node.leftHandSide) {
      final SimpleIdentifier identifier => identifier.name,
      final PropertyAccess access when access.target is ThisExpression =>
        access.propertyName.name,
      _ => null,
    };
    if (name != null) {
      assignments.putIfAbsent(name, () => []).add(node.rightHandSide);
    }

    super.visitAssignmentExpression(node);
  }
}

class _ListPortExposureVisitor extends RecursiveAstVisitor<void> {
  final Map<String, List<Expression>> assignments;
  final RohdSemantics semantics;

  _ListPortExposureVisitor(this.assignments, this.semantics);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (node.methodName.name == 'add' &&
        target is SimpleIdentifier &&
        node.argumentList.arguments.length == 1) {
      final argument = node.argumentList.arguments.single;
      if (argument is MethodInvocation &&
          semantics.isLocalPortFactory(argument)) {
        assignments.putIfAbsent(target.name, () => []).add(argument);
      }
    }
    super.visitMethodInvocation(node);
  }
}

class _FactoryVisitor extends RecursiveAstVisitor<void> {
  final RohdSemantics semantics;
  final void Function() onLocalFactory;

  _FactoryVisitor({required this.semantics, required this.onLocalFactory});

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (semantics.isLocalPortFactory(node)) {
      onLocalFactory();
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitCascadeExpression(CascadeExpression node) {
    if (node.cascadeSections.any(
      (section) =>
          section is MethodInvocation && section.methodName.name == 'connectIO',
    )) {
      onLocalFactory();
    }
    super.visitCascadeExpression(node);
  }
}

bool _isIntentionallyInternal(NodeList<Annotation> metadata) => metadata.any(
  (annotation) =>
      {'protected', 'visibleForTesting'}.contains(annotation.name.name),
);
