// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'package:rohd_analyzer_plugin/src/generated/rohd_rule_registry.dart';

/// Resolved ROHD concepts used by analyzer rules.
class RohdSemantics {
  /// Returns whether [element] is a ROHD `Module` or a subclass of one.
  bool isModuleClass(ClassElement element) {
    for (
      var current = element.supertype?.element;
      current != null;
      current = current.supertype?.element
    ) {
      if (current.name == 'Module' && _isRohdElement(current)) {
        return true;
      }
    }
    return false;
  }

  /// Returns whether [type] is a ROHD hardware value or contains one.
  bool isHardwareType(DartType? type) {
    if (type is! InterfaceType) {
      return false;
    }
    if (_isHardwareElement(type.element)) {
      return true;
    }
    return type.typeArguments.any(isHardwareType);
  }

  bool _isHardwareElement(InterfaceElement element) {
    for (
      InterfaceElement? current = element;
      current != null;
      current = current.supertype?.element
    ) {
      if (_isRohdElement(current) &&
          rohdHardwareTypeRoots.contains(current.name)) {
        return true;
      }
    }
    return false;
  }

  /// Returns whether [creation] invokes the ROHD `Const` constructor.
  bool isRohdConstCreation(InstanceCreationExpression creation) {
    final constructor = creation.constructorName.element;
    final owner = constructor?.enclosingElement;
    return owner is ClassElement &&
        owner.name == 'Const' &&
        _isStrictRohdElement(owner);
  }

  /// Returns whether [invocation] is ROHD's `Logic.inject` or `Logic.put`.
  bool isRohdLogicMutation(MethodInvocation invocation) {
    final method = invocation.methodName.element;
    if (method is! MethodElement ||
        !rohdConstMutationMethods.contains(method.name) ||
        !_isStrictRohdElement(method)) {
      return false;
    }

    final owner = method.enclosingElement;
    return owner is ClassElement && _isRohdLogicClass(owner);
  }

  /// Returns whether [invocation] is ROHD's `Combinational.ssa` factory.
  bool isCombinationalSsa(MethodInvocation invocation) {
    final method = invocation.methodName.element;
    if (method is! MethodElement || method.name != 'ssa') {
      return false;
    }

    final owner = method.enclosingElement;
    return owner is ClassElement &&
        owner.name == 'Combinational' &&
        _isStrictRohdElement(owner);
  }

  /// Returns whether [creation] constructs ROHD's `Combinational` block.
  bool isCombinationalCreation(InstanceCreationExpression creation) {
    final constructor = creation.constructorName.element;
    final owner = constructor?.enclosingElement;
    return owner is ClassElement &&
        owner.name == 'Combinational' &&
        _isStrictRohdElement(owner);
  }

  bool _isRohdLogicClass(ClassElement element) {
    for (
      InterfaceElement? current = element;
      current != null;
      current = current.supertype?.element
    ) {
      if (current.name == 'Logic' && _isStrictRohdElement(current)) {
        return true;
      }
    }
    return false;
  }

  /// Returns whether [invocation] is a named `dart:core` List method.
  bool isCoreListMethod(MethodInvocation invocation, Set<String> names) {
    final method = invocation.methodName.element;
    if (method is! MethodElement || !names.contains(method.name)) {
      return false;
    }
    final owner = method.enclosingElement;
    return owner is ClassElement &&
        owner.name == 'List' &&
        owner.library.uri.toString() == 'dart:core';
  }

  /// Returns whether [invocation] resolves to a legal current-module routine.
  bool isLocalPortFactory(MethodInvocation invocation) {
    final method = invocation.methodName.element;
    if (method is! MethodElement ||
        !rohdLegalExposureMethods.contains(method.name)) {
      return false;
    }
    final owner = method.enclosingElement;
    return owner is ClassElement &&
        _isModuleClassOrBase(owner) &&
        (invocation.target == null || invocation.target is ThisExpression);
  }

  bool _isModuleClassOrBase(ClassElement element) =>
      (element.name == 'Module' && _isRohdElement(element)) ||
      isModuleClass(element);

  bool _isRohdElement(Element element) {
    final uri = element.library?.uri;
    return uri == null ||
        (uri.scheme == 'package' && uri.pathSegments.first == 'rohd');
  }

  bool _isStrictRohdElement(Element element) {
    final uri = element.library?.uri;
    return uri != null &&
        uri.scheme == 'package' &&
        uri.pathSegments.first == 'rohd';
  }
}
