// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/source/source_range.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';

import 'package:rohd_analyzer_plugin/src/rohd_semantics.dart';

/// Converts a directly assigned public `Logic` field into an output getter.
///
/// The fix is deliberately limited to `late final` fields with exactly one
/// assignment in a constructor. This preserves the public read API without
/// guessing whether a mutable or otherwise ambiguous member is an input.
class NonPortPublicHardwareFix extends CorrectionProducerWithDiagnostic {
  /// The kind of fix offered for a provable output field.
  static const outputKind = FixKind(
    'rohd.fix.convertPublicFieldToOutput',
    50,
    'Convert field to a registered output',
  );

  /// The kind of fix offered for a typed input field.
  static const inputKind = FixKind(
    'rohd.fix.convertFieldToInputAccessor',
    50,
    'Convert field to a registered input accessor',
  );

  /// The kind of fix offered for an internal-only field.
  static const protectedKind = FixKind(
    'rohd.fix.protectInternalField',
    50,
    'Make field protected because it is not used outside its class',
  );

  /// The kind of fix offered for a list of logic values used as an output.
  static const arrayOutputKind = FixKind(
    'rohd.fix.convertListToOutputArray',
    50,
    'Convert List<Logic> field to a registered output array',
  );

  /// The kind of fix offered for a `LogicNet` passed to `addInOut`.
  static const inOutKind = FixKind(
    'rohd.fix.convertFieldToInOut',
    50,
    'Convert field to a registered inout port',
  );

  /// The kind of fix offered for a generated list of scalar outputs.
  static const generatedListOutputKind = FixKind(
    'rohd.fix.convertGeneratedListToOutputs',
    50,
    'Convert generated Logic list to registered outputs',
  );

  /// The kind of fix offered for a list whose individual leaves are outputs.
  static const leafListOutputKind = FixKind(
    'rohd.fix.convertListLeavesToOutputs',
    50,
    'Convert list elements to registered outputs',
  );

  /// Creates the correction producer.
  NonPortPublicHardwareFix({required super.context});

  @override
  FixKind get fixKind => outputKind;

  @override
  CorrectionApplicability get applicability =>
      CorrectionApplicability.singleLocation;

  @override
  Future<void> compute(ChangeBuilder builder) async {
    if (!_candidateAvailableFor(fixKind)) {
      return;
    }
    final variable = coveringNode?.thisOrAncestorOfType<VariableDeclaration>();
    final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
    final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
    if (variable == null || declaration == null || classDeclaration == null) {
      return;
    }

    final candidate = fixKind == outputKind
        ? _OutputCandidate.find(
            classDeclaration,
            declaration,
            variable,
            RohdSemantics(),
            unitResult.content,
          )
        : null;
    if (candidate == null) {
      final protectedCandidate = _protectedCandidateForContext();
      if (fixKind == protectedKind && protectedCandidate != null) {
        await builder.addDartFileEdit(unitResult.path, (fileEdit) {
          fileEdit
            ..importLibrary(
              Uri.parse('package:meta/meta.dart'),
              showName: 'protected',
              useShow: true,
            )
            ..addSimpleInsertion(
              protectedCandidate.annotationOffset,
              protectedCandidate.annotationSource,
            );
        });
        return;
      }

      final inOutCandidate = _inOutCandidateForContext();
      if (fixKind == inOutKind && inOutCandidate != null) {
        await builder.addDartFileEdit(unitResult.path, (fileEdit) {
          fileEdit
            ..addSimpleReplacement(
              inOutCandidate.fieldRange,
              inOutCandidate.getterSource,
            )
            ..addSimpleReplacement(
              inOutCandidate.assignmentRange,
              inOutCandidate.localAssignmentSource,
            );
        });
        return;
      }

      final inputCandidate = _inputCandidateForContext();
      if (fixKind == inputKind && inputCandidate != null) {
        await builder.addDartFileEdit(unitResult.path, (fileEdit) {
          fileEdit
            ..addSimpleReplacement(
              inputCandidate.fieldRange,
              inputCandidate.getterSource,
            )
            ..addSimpleReplacement(
              inputCandidate.assignmentRange,
              inputCandidate.localAssignmentSource,
            );
        });
        return;
      }

      final initializedOutputCandidate =
          _initializedOutputCandidateForContext();
      if (fixKind == outputKind && initializedOutputCandidate != null) {
        await builder.addDartFileEdit(unitResult.path, (fileEdit) {
          fileEdit
            ..addSimpleReplacement(
              initializedOutputCandidate.fieldRange,
              initializedOutputCandidate.getterSource,
            )
            ..addSimpleInsertion(
              initializedOutputCandidate.constructorInsertionOffset,
              initializedOutputCandidate.localSource,
            );
        });
        return;
      }

      final generatedListCandidate = _generatedListOutputCandidateForContext();
      if (fixKind == generatedListOutputKind &&
          generatedListCandidate != null) {
        await builder.addDartFileEdit(unitResult.path, (fileEdit) {
          fileEdit
            ..addSimpleReplacement(
              generatedListCandidate.fieldRange,
              generatedListCandidate.getterSource,
            )
            ..addSimpleInsertion(
              generatedListCandidate.constructorInsertionOffset,
              generatedListCandidate.localSource,
            );
        });
        return;
      }

      final leafListCandidate = _leafListOutputCandidateForContext();
      if (fixKind == leafListOutputKind && leafListCandidate != null) {
        await builder.addDartFileEdit(unitResult.path, (fileEdit) {
          fileEdit
            ..addSimpleReplacement(
              leafListCandidate.fieldRange,
              leafListCandidate.fieldSource,
            )
            ..addSimpleInsertion(
              leafListCandidate.constructorInsertionOffset,
              leafListCandidate.constructorSource,
            );
          for (final edit in leafListCandidate.elementEdits) {
            fileEdit.addSimpleReplacement(edit.range, edit.source);
          }
        });
        return;
      }

      final arrayCandidate = _arrayOutputCandidateForContext();
      if (fixKind != arrayOutputKind || arrayCandidate == null) {
        return;
      }
      await builder.addDartFileEdit(unitResult.path, (fileEdit) {
        fileEdit
          ..addSimpleReplacement(
            arrayCandidate.fieldRange,
            arrayCandidate.fieldSource,
          )
          ..addSimpleInsertion(
            arrayCandidate.registrationOffset,
            arrayCandidate.registrationSource,
          );
        for (final edit in arrayCandidate.elementEdits) {
          fileEdit.addSimpleReplacement(edit.range, edit.source);
        }
      });
      return;
    }

    await builder.addDartFileEdit(unitResult.path, (fileEdit) {
      fileEdit
        ..addSimpleReplacement(
          _fieldSourceRange(declaration),
          candidate.getterSource,
        )
        ..addSimpleReplacement(
          candidate.assignmentRange,
          candidate.outputAssignmentSource,
        );
    });
  }

  bool _candidateAvailableFor(FixKind kind) {
    if (kind == protectedKind) {
      return _protectedCandidateForContext() != null;
    }
    if (kind == inOutKind) {
      return _inOutCandidateForContext() != null;
    }
    if (kind == inputKind) {
      return _inputCandidateForContext() != null;
    }
    if (kind == generatedListOutputKind) {
      return _generatedListOutputCandidateForContext() != null;
    }
    if (kind == leafListOutputKind) {
      return _leafListOutputCandidateForContext() != null;
    }
    if (kind == arrayOutputKind) {
      return _arrayOutputCandidateForContext() != null;
    }
    if (_inOutCandidateForContext() != null) {
      return false;
    }
    if (_isLogicNetFieldForContext()) {
      return false;
    }
    return _outputCandidateForContext() != null ||
        _initializedOutputCandidateForContext() != null;
  }

  bool _isLogicNetFieldForContext() {
    final variable = coveringNode?.thisOrAncestorOfType<VariableDeclaration>();
    final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
    return declaration?.fields.type?.toSource() == 'LogicNet';
  }

  _OutputCandidate? _outputCandidateForContext() {
    final node = coveringNode;
    final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
    final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
    final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
    if (variable == null || declaration == null || classDeclaration == null) {
      return null;
    }

    if (_InOutCandidate.find(
          classDeclaration,
          declaration,
          variable,
          unitResult.content,
        ) !=
        null) {
      return null;
    }

    return _OutputCandidate.find(
      classDeclaration,
      declaration,
      variable,
      RohdSemantics(),
      unitResult.content,
    );
  }

  _InitializedOutputCandidate? _initializedOutputCandidateForContext() {
    final node = coveringNode;
    final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
    final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
    final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
    if (variable == null || declaration == null || classDeclaration == null) {
      return null;
    }

    if (_InOutCandidate.find(
          classDeclaration,
          declaration,
          variable,
          unitResult.content,
        ) !=
        null) {
      return null;
    }
    return _InitializedOutputCandidate.find(
      classDeclaration,
      declaration,
      variable,
      unitResult.content,
    );
  }

  _TypedInputCandidate? _inputCandidateForContext() {
    final node = coveringNode;
    final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
    final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
    final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
    if (variable == null || declaration == null || classDeclaration == null) {
      return null;
    }

    return _TypedInputCandidate.find(
      classDeclaration,
      declaration,
      variable,
      unitResult.content,
    );
  }

  _ProtectedCandidate? _protectedCandidateForContext() {
    final node = coveringNode;
    final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
    final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
    final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
    if (variable == null || declaration == null || classDeclaration == null) {
      return null;
    }

    return _ProtectedCandidate.find(
      classDeclaration,
      declaration,
      variable,
      unitResult.unit,
      unitResult.content,
    );
  }

  _ArrayOutputCandidate? _arrayOutputCandidateForContext() {
    final node = coveringNode;
    final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
    final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
    final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
    if (variable == null || declaration == null || classDeclaration == null) {
      return null;
    }

    return _ArrayOutputCandidate.find(
      classDeclaration,
      declaration,
      variable,
      unitResult.content,
    );
  }

  _InOutCandidate? _inOutCandidateForContext() {
    final node = coveringNode;
    final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
    final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
    final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
    if (variable == null || declaration == null || classDeclaration == null) {
      return null;
    }

    return _InOutCandidate.find(
      classDeclaration,
      declaration,
      variable,
      unitResult.content,
    );
  }

  _GeneratedListOutputCandidate? _generatedListOutputCandidateForContext() {
    final node = coveringNode;
    final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
    final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
    final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
    if (variable == null || declaration == null || classDeclaration == null) {
      return null;
    }

    return _GeneratedListOutputCandidate.find(
      classDeclaration,
      declaration,
      variable,
      unitResult.content,
      RohdSemantics(),
    );
  }

  _LeafListOutputCandidate? _leafListOutputCandidateForContext() {
    final node = coveringNode;
    final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
    final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
    final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
    if (variable == null || declaration == null || classDeclaration == null) {
      return null;
    }
    return _LeafListOutputCandidate.find(
      classDeclaration,
      declaration,
      variable,
      unitResult.content,
    );
  }
}

/// Returns the protected annotation offered for a proven internal H001 field.
///
/// This shares the same candidate analysis as the registered Quick Fix and is
/// kept public so analyzer regression tests can verify fix availability.
String? nonPortPublicHardwareProtectedFixAnnotation(
  ResolvedUnitResult unitResult, {
  required int offset,
  required int length,
}) {
  final node = unitResult.unit.nodeCovering(offset: offset, length: length);
  final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
  final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
  final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
  if (variable == null || declaration == null || classDeclaration == null) {
    return null;
  }

  return _ProtectedCandidate.find(
    classDeclaration,
    declaration,
    variable,
    unitResult.unit,
    unitResult.content,
  )?.annotationSource;
}

/// Returns whether the registered output-array Quick Fix is available.
bool nonPortPublicHardwareArrayFixAvailable(
  ResolvedUnitResult unitResult, {
  required int offset,
  required int length,
}) {
  final node = unitResult.unit.nodeCovering(offset: offset, length: length);
  final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
  final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
  final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
  if (variable == null || declaration == null || classDeclaration == null) {
    return false;
  }

  return _ArrayOutputCandidate.find(
        classDeclaration,
        declaration,
        variable,
        unitResult.content,
      ) !=
      null;
}

/// Returns whether the registered inout Quick Fix is available.
bool nonPortPublicHardwareInOutFixAvailable(
  ResolvedUnitResult unitResult, {
  required int offset,
  required int length,
}) {
  final node = unitResult.unit.nodeCovering(offset: offset, length: length);
  final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
  final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
  final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
  if (variable == null || declaration == null || classDeclaration == null) {
    return false;
  }

  return _InOutCandidate.find(
        classDeclaration,
        declaration,
        variable,
        unitResult.content,
      ) !=
      null;
}

/// Returns whether a typed input accessor Quick Fix is available.
bool nonPortPublicHardwareInputFixAvailable(
  ResolvedUnitResult unitResult, {
  required int offset,
  required int length,
}) {
  final node = unitResult.unit.nodeCovering(offset: offset, length: length);
  final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
  final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
  final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
  if (variable == null || declaration == null || classDeclaration == null) {
    return false;
  }

  return _TypedInputCandidate.find(
        classDeclaration,
        declaration,
        variable,
        unitResult.content,
      ) !=
      null;
}

/// Returns whether the scalar registered-output Quick Fix is available.
bool nonPortPublicHardwareOutputFixAvailable(
  ResolvedUnitResult unitResult, {
  required int offset,
  required int length,
}) {
  final node = unitResult.unit.nodeCovering(offset: offset, length: length);
  final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
  final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
  final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
  if (variable == null || declaration == null || classDeclaration == null) {
    return false;
  }

  if (_InOutCandidate.find(
        classDeclaration,
        declaration,
        variable,
        unitResult.content,
      ) !=
      null) {
    return false;
  }
  if (declaration.fields.type?.toSource() == 'LogicNet') {
    return false;
  }

  return _OutputCandidate.find(
        classDeclaration,
        declaration,
        variable,
        RohdSemantics(),
        unitResult.content,
      ) !=
      null;
}

/// Returns whether an initialized scalar output Quick Fix is available.
bool nonPortPublicHardwareInitializedOutputFixAvailable(
  ResolvedUnitResult unitResult, {
  required int offset,
  required int length,
}) {
  final node = unitResult.unit.nodeCovering(offset: offset, length: length);
  final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
  final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
  final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
  if (variable == null || declaration == null || classDeclaration == null) {
    return false;
  }
  if (_InOutCandidate.find(
        classDeclaration,
        declaration,
        variable,
        unitResult.content,
      ) !=
      null) {
    return false;
  }
  return _InitializedOutputCandidate.find(
        classDeclaration,
        declaration,
        variable,
        unitResult.content,
      ) !=
      null;
}

/// Returns whether the generated-list registered-output Quick Fix is
/// available.
bool nonPortPublicHardwareGeneratedListFixAvailable(
  ResolvedUnitResult unitResult, {
  required int offset,
  required int length,
}) {
  final node = unitResult.unit.nodeCovering(offset: offset, length: length);
  final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
  final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
  final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
  if (variable == null || declaration == null || classDeclaration == null) {
    return false;
  }

  return _GeneratedListOutputCandidate.find(
        classDeclaration,
        declaration,
        variable,
        unitResult.content,
        RohdSemantics(),
      ) !=
      null;
}

/// Returns whether the leaf-list registered-output Quick Fix is available.
bool nonPortPublicHardwareLeafListFixAvailable(
  ResolvedUnitResult unitResult, {
  required int offset,
  required int length,
}) {
  final node = unitResult.unit.nodeCovering(offset: offset, length: length);
  final variable = node?.thisOrAncestorOfType<VariableDeclaration>();
  final declaration = variable?.thisOrAncestorOfType<FieldDeclaration>();
  final classDeclaration = variable?.thisOrAncestorOfType<ClassDeclaration>();
  if (variable == null || declaration == null || classDeclaration == null) {
    return false;
  }
  return _LeafListOutputCandidate.find(
        classDeclaration,
        declaration,
        variable,
        unitResult.content,
      ) !=
      null;
}

class _GeneratedListOutputCandidate {
  final SourceRange fieldRange;
  final int constructorInsertionOffset;
  final String getterSource;
  final String localSource;

  _GeneratedListOutputCandidate({
    required this.fieldRange,
    required this.constructorInsertionOffset,
    required this.getterSource,
    required this.localSource,
  });

  static _GeneratedListOutputCandidate? find(
    ClassDeclaration classDeclaration,
    FieldDeclaration declaration,
    VariableDeclaration variable,
    String content,
    RohdSemantics semantics,
  ) {
    final initializer = variable.initializer;
    final elementType = variable.declaredFragment?.element.type;
    final typeArguments = elementType is InterfaceType
        ? elementType.typeArguments
        : const <DartType>[];
    final declaredType = declaration.fields.type;
    final declaredTypeArguments = declaredType is NamedType
        ? declaredType.typeArguments?.arguments
        : null;
    final elementTypeNode = declaredTypeArguments?.length == 1
        ? declaredTypeArguments!.single
        : null;
    if (!declaration.fields.isFinal ||
        typeArguments.length != 1 ||
        elementTypeNode == null ||
        !semantics.isHardwareType(typeArguments.single) ||
        initializer is! InstanceCreationExpression ||
        initializer.constructorName.type.name.lexeme != 'List' ||
        initializer.constructorName.name?.name != 'generate' ||
        initializer.argumentList.arguments.length != 2) {
      return null;
    }
    final invocation = initializer;

    final callback = invocation.argumentList.arguments[1];
    if (callback is! FunctionExpression ||
        callback.parameters?.parameters.length != 1 ||
        callback.body is! ExpressionFunctionBody) {
      return null;
    }
    final body = (callback.body as ExpressionFunctionBody).expression;
    if (body is! InstanceCreationExpression ||
        !semantics.isHardwareType(body.staticType)) {
      return null;
    }

    final nameArgument = body.argumentList.arguments
        .whereType<NamedExpression>()
        .where((argument) => argument.name.label.name == 'name');
    if (nameArgument.length != 1) {
      return null;
    }

    final classBody = classDeclaration.body;
    final constructors = classBody is BlockClassBody
        ? classBody.members.whereType<ConstructorDeclaration>().toList()
        : <ConstructorDeclaration>[];
    if (constructors.length != 1) {
      return null;
    }

    final callbackParameter = callback.parameters!.parameters.single;
    final callbackParameterSource = content.substring(
      callbackParameter.offset,
      callbackParameter.end,
    );
    final dimensionsSource = content.substring(
      invocation.argumentList.arguments.first.offset,
      invocation.argumentList.arguments.first.end,
    );
    final nameSource = content.substring(
      nameArgument.single.expression.offset,
      nameArgument.single.expression.end,
    );
    final fieldName = variable.name.lexeme;
    final elementTypeSource = content.substring(
      elementTypeNode.offset,
      elementTypeNode.end,
    );
    final typeSource = content.substring(
      declaration.fields.type!.offset,
      declaration.fields.type!.end,
    );
    final indentation = _lineIndentation(content, constructors.single.offset);
    final bodySource = content.substring(body.offset, body.end);
    final isLogic = elementTypeSource == 'Logic';
    final isLogicNet = elementTypeSource == 'LogicNet';
    final accessor = isLogic
        ? 'output($nameSource)'
        : 'output($nameSource) as $elementTypeSource';
    final registration = isLogic
        ? 'addOutput($nameSource)'
        : isLogicNet
        ? 'addTypedInOut($nameSource, $bodySource)'
        : 'addTypedOutput($nameSource, $bodySource)';
    final localSource =
        '\n$indentation  final $fieldName = List.generate('
        '$dimensionsSource, ($callbackParameterSource) => '
        '$registration);';

    return _GeneratedListOutputCandidate(
      fieldRange: _fieldSourceRange(declaration),
      constructorInsertionOffset: constructors.single.body.beginToken.end,
      getterSource:
          '$typeSource get $fieldName => List.generate('
          '$dimensionsSource, ($callbackParameterSource) => '
          '$accessor);',
      localSource: localSource,
    );
  }
}

String _lineIndentation(String content, int offset) {
  final lineStart = content.lastIndexOf('\n', offset - 1) + 1;
  final line = content.substring(lineStart, offset);
  return line.substring(0, line.length - line.trimLeft().length);
}

SourceRange _fieldSourceRange(FieldDeclaration declaration) =>
    SourceRange(declaration.offset, declaration.length);

class _TypedInputCandidate {
  final SourceRange fieldRange;
  final SourceRange assignmentRange;
  final String getterSource;
  final String localAssignmentSource;

  _TypedInputCandidate({
    required this.fieldRange,
    required this.assignmentRange,
    required this.getterSource,
    required this.localAssignmentSource,
  });

  static _TypedInputCandidate? find(
    ClassDeclaration classDeclaration,
    FieldDeclaration declaration,
    VariableDeclaration variable,
    String content,
  ) {
    final typeSource = declaration.fields.type?.toSource();
    if (!declaration.fields.isLate ||
        !declaration.fields.isFinal ||
        variable.initializer != null ||
        (typeSource != 'LogicStructure' && typeSource != 'LogicArray')) {
      return null;
    }

    final fieldElement = variable.declaredFragment?.element;
    if (fieldElement == null) {
      return null;
    }

    final assignments = <AssignmentExpression>[];
    classDeclaration.accept(
      _FieldAssignmentVisitor(fieldElement, variable.name.lexeme, assignments),
    );
    if (assignments.length != 1) {
      return null;
    }

    final assignment = assignments.single;
    final constructor = assignment
        .thisOrAncestorOfType<ConstructorDeclaration>();
    if (constructor == null) {
      return null;
    }

    final inputInvocation = _TypedInputInvocationVisitor(
      variable.name.lexeme,
      constructor,
    ).find(classDeclaration);
    if (inputInvocation == null) {
      return null;
    }

    final portName = content.substring(
      inputInvocation.argumentList.arguments.first.offset,
      inputInvocation.argumentList.arguments.first.end,
    );
    final fieldName = variable.name.lexeme;
    final rightHandSide = content.substring(
      assignment.rightHandSide.offset,
      assignment.rightHandSide.end,
    );
    return _TypedInputCandidate(
      fieldRange: _fieldSourceRange(declaration),
      assignmentRange: SourceRange(assignment.offset, assignment.length),
      getterSource:
          '$typeSource get $fieldName => '
          'inputSource($portName) as $typeSource;',
      localAssignmentSource: 'final $fieldName = $rightHandSide',
    );
  }
}

class _TypedInputInvocationVisitor extends RecursiveAstVisitor<void> {
  final String fieldName;
  final ConstructorDeclaration constructor;
  MethodInvocation? invocation;

  _TypedInputInvocationVisitor(this.fieldName, this.constructor);

  MethodInvocation? find(ClassDeclaration classDeclaration) {
    classDeclaration.accept(this);
    return invocation;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (invocation != null ||
        node.thisOrAncestorOfType<ConstructorDeclaration>() != constructor ||
        node.argumentList.arguments.length < 2 ||
        !{
          'addInput',
          'addTypedInput',
          'addInputArray',
        }.contains(node.methodName.name)) {
      super.visitMethodInvocation(node);
      return;
    }

    final source = node.argumentList.arguments[1];
    final root = source is SimpleIdentifier
        ? source.name
        : source is PropertyAccess && source.target is ThisExpression
        ? source.propertyName.name
        : null;
    if (root == fieldName) {
      invocation = node;
    }
    super.visitMethodInvocation(node);
  }
}

class _InOutCandidate {
  final SourceRange fieldRange;
  final SourceRange assignmentRange;
  final String getterSource;
  final String localAssignmentSource;

  _InOutCandidate({
    required this.fieldRange,
    required this.assignmentRange,
    required this.getterSource,
    required this.localAssignmentSource,
  });

  static _InOutCandidate? find(
    ClassDeclaration classDeclaration,
    FieldDeclaration declaration,
    VariableDeclaration variable,
    String content,
  ) {
    if (!declaration.fields.isLate ||
        !declaration.fields.isFinal ||
        declaration.fields.type?.toSource() != 'LogicNet' ||
        variable.initializer != null) {
      return null;
    }

    final fieldElement = variable.declaredFragment?.element;
    if (fieldElement == null) {
      return null;
    }

    final assignments = <AssignmentExpression>[];
    classDeclaration.accept(
      _FieldAssignmentVisitor(fieldElement, variable.name.lexeme, assignments),
    );
    if (assignments.length != 1) {
      return null;
    }

    final assignment = assignments.single;
    final constructor = assignment
        .thisOrAncestorOfType<ConstructorDeclaration>();
    if (constructor == null) {
      return null;
    }

    final inOutInvocation = _InOutInvocationVisitor(
      variable.name.lexeme,
      constructor,
    ).find(classDeclaration);
    if (inOutInvocation == null) {
      return null;
    }

    final portName = content.substring(
      inOutInvocation.argumentList.arguments.first.offset,
      inOutInvocation.argumentList.arguments.first.end,
    );
    final fieldName = variable.name.lexeme;
    final rightHandSide = content.substring(
      assignment.rightHandSide.offset,
      assignment.rightHandSide.end,
    );
    return _InOutCandidate(
      fieldRange: _fieldSourceRange(declaration),
      assignmentRange: SourceRange(assignment.offset, assignment.length),
      getterSource:
          'LogicNet get $fieldName => inOutSource($portName) as LogicNet;',
      localAssignmentSource: 'final $fieldName = $rightHandSide',
    );
  }
}

class _InOutInvocationVisitor extends RecursiveAstVisitor<void> {
  final String fieldName;
  final ConstructorDeclaration constructor;
  MethodInvocation? invocation;

  _InOutInvocationVisitor(this.fieldName, this.constructor);

  MethodInvocation? find(ClassDeclaration classDeclaration) {
    classDeclaration.accept(this);
    return invocation;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (invocation != null ||
        node.thisOrAncestorOfType<ConstructorDeclaration>() != constructor ||
        node.methodName.name != 'addInOut' ||
        node.argumentList.arguments.length < 2) {
      super.visitMethodInvocation(node);
      return;
    }

    final source = node.argumentList.arguments[1];
    final root = source is SimpleIdentifier
        ? source.name
        : source is PropertyAccess && source.target is ThisExpression
        ? source.propertyName.name
        : null;
    if (root == fieldName) {
      invocation = node;
    }
    super.visitMethodInvocation(node);
  }
}

class _OutputCandidate {
  final SourceRange assignmentRange;
  final String getterSource;
  final String outputAssignmentSource;

  _OutputCandidate(
    this.assignmentRange,
    this.getterSource,
    this.outputAssignmentSource,
  );

  static _OutputCandidate? find(
    ClassDeclaration classDeclaration,
    FieldDeclaration declaration,
    VariableDeclaration variable,
    RohdSemantics semantics,
    String content,
  ) {
    final type = declaration.fields.type;
    final isLogic =
        semantics.isHardwareType(variable.declaredFragment?.element.type) &&
        variable.declaredFragment?.element.type.getDisplayString() == 'Logic';
    final isUninitializedLateField =
        declaration.fields.isLate && variable.initializer == null;
    final isInitializedLogicField =
        declaration.fields.isFinal &&
        variable.initializer is InstanceCreationExpression &&
        isLogic;
    if (!declaration.fields.isFinal ||
        type == null ||
        (!isUninitializedLateField && !isInitializedLogicField)) {
      return null;
    }

    final fieldElement = variable.declaredFragment?.element;
    if (fieldElement == null) {
      return null;
    }

    final assignments = <AssignmentExpression>[];
    classDeclaration.accept(
      _FieldAssignmentVisitor(fieldElement, variable.name.lexeme, assignments),
    );
    Expression? driveExpression;
    SourceRange? driveRange;
    if (assignments.length == 1) {
      if (isInitializedLogicField &&
          assignments.single.operator.lexeme != '<=') {
        return null;
      }
      driveExpression = assignments.single.rightHandSide;
      driveRange = SourceRange(
        assignments.single.offset,
        assignments.single.length,
      );
    } else if (isInitializedLogicField && assignments.isEmpty) {
      final drives = <BinaryExpression>[];
      classDeclaration.accept(_FieldDriveVisitor(variable.name.lexeme, drives));
      if (drives.length != 1) {
        return null;
      }
      driveExpression = drives.single.rightOperand;
      driveRange = SourceRange(drives.single.offset, drives.single.length);
    } else {
      return null;
    }
    final rightHandSide = driveExpression;
    final typeSource = content.substring(type.offset, type.end);
    final name = variable.name.lexeme;
    final expressionSource = content.substring(
      rightHandSide.offset,
      rightHandSide.end,
    );

    return _OutputCandidate(
      driveRange,
      "$typeSource get $name => output('$name');",
      "addOutput('$name', width: ($expressionSource).width) <= "
          '($expressionSource)',
    );
  }
}

/// Provides the protected-field Quick Fix with its specific title.
class NonPortPublicHardwareProtectedFix extends NonPortPublicHardwareFix {
  /// Creates the protected-field correction producer.
  NonPortPublicHardwareProtectedFix({required super.context});

  @override
  FixKind get fixKind => NonPortPublicHardwareFix.protectedKind;
}

/// Provides the inout Quick Fix with its specific title.
class NonPortPublicHardwareInOutFix extends NonPortPublicHardwareFix {
  /// Creates the inout correction producer.
  NonPortPublicHardwareInOutFix({required super.context});

  @override
  FixKind get fixKind => NonPortPublicHardwareFix.inOutKind;
}

/// Provides the typed-input accessor Quick Fix with its specific title.
class NonPortPublicHardwareInputFix extends NonPortPublicHardwareFix {
  /// Creates the typed-input correction producer.
  NonPortPublicHardwareInputFix({required super.context});

  @override
  FixKind get fixKind => NonPortPublicHardwareFix.inputKind;
}

/// Provides the generated-list Quick Fix with its specific title.
class NonPortPublicHardwareGeneratedListFix extends NonPortPublicHardwareFix {
  /// Creates the generated-list correction producer.
  NonPortPublicHardwareGeneratedListFix({required super.context});

  @override
  FixKind get fixKind => NonPortPublicHardwareFix.generatedListOutputKind;
}

/// Provides the leaf-list output Quick Fix with its specific title.
class NonPortPublicHardwareLeafListFix extends NonPortPublicHardwareFix {
  /// Creates the leaf-list correction producer.
  NonPortPublicHardwareLeafListFix({required super.context});

  @override
  FixKind get fixKind => NonPortPublicHardwareFix.leafListOutputKind;
}

/// Provides the output-array Quick Fix with its specific title.
class NonPortPublicHardwareArrayFix extends NonPortPublicHardwareFix {
  /// Creates the output-array correction producer.
  NonPortPublicHardwareArrayFix({required super.context});

  @override
  FixKind get fixKind => NonPortPublicHardwareFix.arrayOutputKind;
}

class _InitializedOutputCandidate {
  final SourceRange fieldRange;
  final int constructorInsertionOffset;
  final String getterSource;
  final String localSource;

  _InitializedOutputCandidate({
    required this.fieldRange,
    required this.constructorInsertionOffset,
    required this.getterSource,
    required this.localSource,
  });

  static _InitializedOutputCandidate? find(
    ClassDeclaration classDeclaration,
    FieldDeclaration declaration,
    VariableDeclaration variable,
    String content,
  ) {
    final initializer = variable.initializer;
    if (!declaration.fields.isFinal ||
        declaration.fields.type?.toSource() != 'Logic' ||
        initializer == null ||
        variable.declaredFragment?.element.type.getDisplayString() != 'Logic') {
      return null;
    }
    final body = classDeclaration.body;
    final constructors = body is BlockClassBody
        ? body.members
              .whereType<ConstructorDeclaration>()
              .where((constructor) => constructor.body is BlockFunctionBody)
              .toList()
        : <ConstructorDeclaration>[];
    if (constructors.length != 1) {
      return null;
    }

    final constructor = constructors.single;
    final fieldName = variable.name.lexeme;
    final initializerSource = content.substring(
      initializer.offset,
      initializer.end,
    );
    final lineStart = content.lastIndexOf('\n', constructor.offset - 1) + 1;
    final indentation = content.substring(lineStart, constructor.offset);
    return _InitializedOutputCandidate(
      fieldRange: _fieldSourceRange(declaration),
      constructorInsertionOffset: constructor.body.beginToken.end,
      getterSource: "Logic get $fieldName => output('$fieldName');",
      localSource:
          "\n$indentation  final $fieldName = addOutput('$fieldName');\n"
          '$indentation  $fieldName <= $initializerSource;',
    );
  }
}

class _ProtectedCandidate {
  final int annotationOffset;
  final String annotationSource;

  _ProtectedCandidate(this.annotationOffset, this.annotationSource);

  static _ProtectedCandidate? find(
    ClassDeclaration classDeclaration,
    FieldDeclaration declaration,
    VariableDeclaration variable,
    CompilationUnit unit,
    String content,
  ) {
    final classElement = classDeclaration.declaredFragment?.element;
    final fieldElement = variable.declaredFragment?.element;
    if (classElement == null ||
        fieldElement == null ||
        !(classElement.name ?? '').startsWith('_') ||
        declaration.metadata.isNotEmpty ||
        _hasExternalReference(unit, classDeclaration, fieldElement)) {
      return null;
    }

    final lineStart = content.lastIndexOf('\n', declaration.offset - 1) + 1;
    final indentation = content.substring(lineStart, declaration.offset);
    return _ProtectedCandidate(declaration.offset, '@protected\n$indentation');
  }

  static bool _hasExternalReference(
    CompilationUnit unit,
    ClassDeclaration classDeclaration,
    Element fieldElement,
  ) {
    var externalReference = false;
    unit.accept(
      _ExternalFieldReferenceVisitor(
        classDeclaration,
        fieldElement,
        onExternalReference: () => externalReference = true,
      ),
    );
    return externalReference;
  }
}

class _ArrayOutputCandidate {
  final SourceRange fieldRange;
  final String fieldSource;
  final int registrationOffset;
  final String registrationSource;
  final List<_ArrayElementEdit> elementEdits;

  _ArrayOutputCandidate({
    required this.fieldRange,
    required this.fieldSource,
    required this.registrationOffset,
    required this.registrationSource,
    required this.elementEdits,
  });

  static _ArrayOutputCandidate? find(
    ClassDeclaration classDeclaration,
    FieldDeclaration declaration,
    VariableDeclaration variable,
    String content,
  ) {
    final classElement = classDeclaration.declaredFragment?.element;
    final fieldElement = variable.declaredFragment?.element;
    final initializer = variable.initializer;
    if (classElement == null ||
        fieldElement == null ||
        (classElement.name ?? '').startsWith('_') ||
        declaration.isStatic ||
        declaration.metadata.isNotEmpty ||
        initializer is! ListLiteral ||
        initializer.elements.isNotEmpty ||
        !declaration.fields.isFinal ||
        variable.name.lexeme.isEmpty ||
        _LeafListOutputCandidate._hasRswizzle(classDeclaration, variable)) {
      return null;
    }

    final addInvocations = <MethodInvocation>[];
    classDeclaration.accept(
      _ListAddVisitor(fieldElement.type, variable.name.lexeme, addInvocations),
    );
    if (addInvocations.length < 2) {
      return null;
    }

    final constructor = addInvocations.first
        .thisOrAncestorOfType<ConstructorDeclaration>();
    if (constructor == null ||
        addInvocations.any(
          (invocation) =>
              invocation.thisOrAncestorOfType<ConstructorDeclaration>() !=
              constructor,
        )) {
      return null;
    }

    final loopInvocation = addInvocations.firstWhere(
      (invocation) => invocation.thisOrAncestorOfType<ForStatement>() != null,
      orElse: () => addInvocations.first,
    );
    final loop = loopInvocation.thisOrAncestorOfType<ForStatement>();
    if (loop == null) {
      return null;
    }

    final loopSource = content.substring(loop.offset, loop.end);
    final loopMatch = RegExp(
      r'for\s*\(\s*(?:var|final|int)\s+([A-Za-z_]\w*)[^;]*;\s*'
      r'\1\s*<\s*([A-Za-z_]\w*)',
    ).firstMatch(loopSource);
    if (loopMatch == null) {
      return null;
    }
    final indexName = loopMatch.group(1)!;
    final dimensionName = loopMatch.group(2)!;
    final firstExpression = addInvocations.first.argumentList.arguments.single;
    final elementWidth = content.substring(
      firstExpression.offset,
      firstExpression.end,
    );
    final fieldName = variable.name.lexeme;
    final lineStart = content.lastIndexOf('\n', loop.offset - 1) + 1;
    final indentation = content.substring(lineStart, loop.offset);
    final registration =
        "$fieldName = addOutputArray('$fieldName', "
        'dimensions: [$dimensionName + 1], elementWidth: '
        '$elementWidth.width);\n$indentation';
    final edits = <_ArrayElementEdit>[];
    for (final invocation in addInvocations) {
      final expression = content.substring(
        invocation.argumentList.arguments.single.offset,
        invocation.argumentList.arguments.single.end,
      );
      final enclosingLoop = invocation.thisOrAncestorOfType<ForStatement>();
      final index = enclosingLoop == null
          ? '$fieldName.elements.length - 1'
          : indexName;
      edits.add(
        _ArrayElementEdit(
          SourceRange(invocation.offset, invocation.length),
          '$fieldName.elements[$index] <= $expression',
        ),
      );
    }

    return _ArrayOutputCandidate(
      fieldRange: _fieldSourceRange(declaration),
      fieldSource: 'late final LogicArray $fieldName',
      registrationOffset: loop.offset,
      registrationSource: registration,
      elementEdits: edits,
    );
  }
}

class _LeafListOutputCandidate {
  final SourceRange fieldRange;
  final String fieldSource;
  final int constructorInsertionOffset;
  final String constructorSource;
  final List<_ArrayElementEdit> elementEdits;

  _LeafListOutputCandidate({
    required this.fieldRange,
    required this.fieldSource,
    required this.constructorInsertionOffset,
    required this.constructorSource,
    required this.elementEdits,
  });

  static _LeafListOutputCandidate? find(
    ClassDeclaration classDeclaration,
    FieldDeclaration declaration,
    VariableDeclaration variable,
    String content,
  ) {
    final fieldElement = variable.declaredFragment?.element;
    final initializer = variable.initializer;
    if (fieldElement == null ||
        declaration.isStatic ||
        !declaration.fields.isFinal ||
        initializer is! ListLiteral ||
        initializer.elements.isNotEmpty ||
        variable.declaredFragment?.element.type.getDisplayString() !=
            'List<Logic>') {
      return null;
    }

    final addInvocations = <MethodInvocation>[];
    classDeclaration.accept(
      _ListAddVisitor(fieldElement.type, variable.name.lexeme, addInvocations),
    );
    if (addInvocations.length < 2 ||
        !_hasRswizzle(classDeclaration, variable)) {
      return null;
    }

    final constructor = addInvocations.first
        .thisOrAncestorOfType<ConstructorDeclaration>();
    if (constructor == null ||
        addInvocations.any(
          (invocation) =>
              invocation.thisOrAncestorOfType<ConstructorDeclaration>() !=
              constructor,
        )) {
      return null;
    }

    final loopInvocation = addInvocations.firstWhere(
      (invocation) => invocation.thisOrAncestorOfType<ForStatement>() != null,
      orElse: () => addInvocations.first,
    );
    final loop = loopInvocation.thisOrAncestorOfType<ForStatement>();
    if (loop == null) {
      return null;
    }
    final loopSource = content.substring(loop.offset, loop.end);
    final loopMatch = RegExp(
      r'for\s*\(\s*(?:var|final|int)\s+([A-Za-z_]\w*)[^;]*;\s*'
      r'\1\s*<\s*([A-Za-z_]\w*)',
    ).firstMatch(loopSource);
    if (loopMatch == null) {
      return null;
    }

    final indexName = loopMatch.group(1)!;
    final fieldName = variable.name.lexeme;
    final privateName = '_$fieldName';
    final lineStart = content.lastIndexOf('\n', loop.offset - 1) + 1;
    final indentation = content.substring(lineStart, loop.offset);
    final edits = <_ArrayElementEdit>[];
    for (final invocation in addInvocations) {
      final expression = content.substring(
        invocation.argumentList.arguments.single.offset,
        invocation.argumentList.arguments.single.end,
      );
      final enclosingLoop = invocation.thisOrAncestorOfType<ForStatement>();
      final nameExpression = enclosingLoop == null
          ? "'${fieldName}_\${$privateName.length}'"
          : "'${fieldName}_\$$indexName'";
      edits.add(
        _ArrayElementEdit(
          SourceRange(invocation.offset, invocation.length),
          '$privateName.add(addOutput($nameExpression, '
          'width: $expression.width))',
        ),
      );
    }

    return _LeafListOutputCandidate(
      fieldRange: _fieldSourceRange(declaration),
      fieldSource:
          'late final List<Logic> $privateName;\n'
          '${indentation}List<Logic> get $fieldName => $privateName;',
      constructorInsertionOffset: loop.offset,
      constructorSource: '$privateName = <Logic>[];\n$indentation',
      elementEdits: edits,
    );
  }

  static bool _hasRswizzle(
    ClassDeclaration classDeclaration,
    VariableDeclaration variable,
  ) {
    var found = false;
    classDeclaration.accept(
      _RswizzleVisitor(variable.name.lexeme, () {
        found = true;
      }),
    );
    return found;
  }
}

class _RswizzleVisitor extends RecursiveAstVisitor<void> {
  final String fieldName;
  final void Function() onFound;

  _RswizzleVisitor(this.fieldName, this.onFound);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (node.methodName.name == 'rswizzle' &&
        target is SimpleIdentifier &&
        target.name == fieldName) {
      onFound();
    }
    super.visitMethodInvocation(node);
  }
}

class _ArrayElementEdit {
  final SourceRange range;
  final String source;

  _ArrayElementEdit(this.range, this.source);
}

class _ListAddVisitor extends RecursiveAstVisitor<void> {
  final DartType fieldType;
  final String fieldName;
  final List<MethodInvocation> invocations;

  _ListAddVisitor(this.fieldType, this.fieldName, this.invocations);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (node.methodName.name == 'add' &&
        node.argumentList.arguments.length == 1 &&
        target is SimpleIdentifier &&
        target.name == fieldName &&
        target.staticType == fieldType) {
      invocations.add(node);
    }
    super.visitMethodInvocation(node);
  }
}

class _ExternalFieldReferenceVisitor extends RecursiveAstVisitor<void> {
  final ClassDeclaration owner;
  final Element fieldElement;
  final void Function() onExternalReference;

  _ExternalFieldReferenceVisitor(
    this.owner,
    this.fieldElement, {
    required this.onExternalReference,
  });

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final property = fieldElement is PropertyInducingElement
        ? fieldElement as PropertyInducingElement
        : null;
    final referencedElement = node.element;
    final isFieldReference =
        referencedElement == fieldElement ||
        referencedElement == property?.getter ||
        referencedElement == property?.setter;
    if (isFieldReference &&
        node.thisOrAncestorOfType<ClassDeclaration>() != owner) {
      onExternalReference();
    }
    super.visitSimpleIdentifier(node);
  }
}

class _FieldAssignmentVisitor extends RecursiveAstVisitor<void> {
  final Element fieldElement;
  final String fieldName;
  final List<AssignmentExpression> assignments;

  _FieldAssignmentVisitor(this.fieldElement, this.fieldName, this.assignments);

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final writeElement = node.writeElement;
    if (writeElement != null &&
        writeElement.name == fieldName &&
        writeElement.enclosingElement == fieldElement.enclosingElement &&
        node.thisOrAncestorOfType<ConstructorDeclaration>() != null) {
      assignments.add(node);
    }

    super.visitAssignmentExpression(node);
  }
}

class _FieldDriveVisitor extends RecursiveAstVisitor<void> {
  final String fieldName;
  final List<BinaryExpression> drives;

  _FieldDriveVisitor(this.fieldName, this.drives);

  @override
  void visitBinaryExpression(BinaryExpression node) {
    if (node.operator.lexeme == '<=' &&
        node.leftOperand is SimpleIdentifier &&
        (node.leftOperand as SimpleIdentifier).name == fieldName &&
        node.thisOrAncestorOfType<ConstructorDeclaration>() != null) {
      drives.add(node);
    }
    super.visitBinaryExpression(node);
  }
}
