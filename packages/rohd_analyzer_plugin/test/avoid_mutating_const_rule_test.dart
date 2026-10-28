// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:analysis_server_plugin/registry.dart';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/error/error.dart';
import 'package:rohd_analyzer_plugin/main.dart';
import 'package:rohd_analyzer_plugin/src/avoid_mutating_const_rule.dart';
import 'package:rohd_analyzer_plugin/src/non_port_public_hardware_rule.dart';
import 'package:rohd_analyzer_plugin/src/ssa_read_before_write_rule.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory application;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'rohd_analyzer_plugin_test_',
    );
    application = Directory('${temporaryDirectory.path}/application')
      ..createSync();
    final rohd = Directory('${temporaryDirectory.path}/rohd')..createSync();
    Directory('${application.path}/lib').createSync();
    Directory('${application.path}/.dart_tool').createSync();
    Directory('${rohd.path}/lib').createSync();
    File('${application.path}/pubspec.yaml').writeAsStringSync(
      'name: application\n'
      'environment:\n'
      "  sdk: '>=3.10.0 <4.0.0'\n",
    );
    File('${rohd.path}/lib/rohd.dart').writeAsStringSync('''
library rohd;

class Logic {
  void inject(Object? value) {}
  void put(Object? value) {}
}

class Const extends Logic {
  Const(Object? value, {int? width});
}
''');
    File(
      '${application.path}/.dart_tool/package_config.json',
    ).writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'application',
            'rootUri': application.uri.toString(),
            'packageUri': 'lib/',
            'languageVersion': '3.10',
          },
          {
            'name': 'rohd',
            'rootUri': rohd.uri.toString(),
            'packageUri': 'lib/',
            'languageVersion': '3.10',
          },
        ],
      }),
    );
  });

  tearDown(() {
    temporaryDirectory.deleteSync(recursive: true);
  });

  test(
    'reports the ROHD-HCL add/index regression for inject and put',
    () async {
      final methods = await _violations(application, '''
import 'package:rohd/rohd.dart';

void drive() {
  final vec = <Logic>[];
  vec.add(Const(0, width: 8));
  vec.add(Const(1, width: 8));
  vec[0].inject(2);
  vec[1].put(3);
}
''');

      expect(methods, ['inject', 'put']);
    },
  );

  test(
    'reports direct, typed alias, alias chain, and generated list',
    () async {
      final methods = await _violations(application, '''
import 'package:rohd/rohd.dart';

void drive() {
  Const(0).inject(1);
  Logic signal = Const(0);
  final alias = signal;
  alias.put(1);
  final generated = List<Logic>.generate(2, (_) => Const(0));
  generated[0].inject(1);
}
''');

      expect(methods, ['inject', 'put', 'inject']);
    },
  );

  test('suppresses mutable, mixed, unknown, and invalidated aliases', () async {
    final methods = await _violations(application, '''
import 'package:rohd/rohd.dart';

void fill(List<Logic> values) {}

void drive(Logic input) {
  final mutable = Logic();
  mutable.inject(1);

  final mixed = <Logic>[];
  final mixedAlias = mixed;
  mixed.add(Const(0));
  mixedAlias.add(input);
  mixed[0].put(1);

  final unknown = <Logic>[];
  unknown.add(Const(0));
  fill(unknown);
  unknown[0].inject(1);
}
''');

    expect(methods, isEmpty);
  });

  test('ignores unrelated Const and similarly named methods', () async {
    final methods = await _violations(application, '''
import 'package:rohd/rohd.dart' hide Const;

class Const {
  void inject(Object? value) {}
  void put(Object? value) {}
}

void drive() {
  final value = Const();
  value.inject(1);
  value.put(1);
}
''');

    expect(methods, isEmpty);
  });

  test('plugin adopts all warning rules', () {
    final rules = rohdWarningRules();

    expect(rules, hasLength(3));
    expect(rules.whereType<NonPortPublicHardwareRule>(), hasLength(1));
    expect(rules.whereType<AvoidMutatingConstRule>(), hasLength(1));
    expect(rules.whereType<SsaReadBeforeWriteRule>(), hasLength(1));
  });

  test('plugin registers the H001 Quick Fix', () {
    final registry = _CapturingPluginRegistry();

    RohdAnalyzerPlugin().register(registry);

    expect(
      registry.fixRegistrations,
      contains('rohd_hierarchy/non_port_public_hardware'),
    );
  });
}

class _CapturingPluginRegistry implements PluginRegistry {
  final fixRegistrations = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #registerFixForRule) {
      final code = invocation.positionalArguments.first as DiagnosticCode;
      fixRegistrations.add(code.lowerCaseName);
      return null;
    }
    return null;
  }
}

Future<List<String>> _violations(Directory application, String source) async {
  final path = '${application.path}/lib/main.dart';
  File(path).writeAsStringSync(source);
  final collection = AnalysisContextCollection(
    includedPaths: [application.path],
  );
  final result = await collection
      .contextFor(path)
      .currentSession
      .getResolvedUnit(path);
  expect(result, isA<ResolvedUnitResult>());
  final unit = (result as ResolvedUnitResult).unit;
  return findConstMutationInvocations(
    unit,
  ).map((invocation) => invocation.methodName.name).toList();
}
