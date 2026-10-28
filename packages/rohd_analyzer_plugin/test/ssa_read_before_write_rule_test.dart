// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// ssa_read_before_write_rule_test.dart
// Tests for the ROHD SSA read-before-write analyzer rule.
//
// 2026 September
// Author: ROHD contributors

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:rohd_analyzer_plugin/src/ssa_read_before_write_rule.dart';
import 'package:test/test.dart';

late Directory _application;

void main() {
  late Directory temporaryDirectory;
  late Directory application;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'rohd_analyzer_plugin_ssa_test_',
    );
    application = Directory('${temporaryDirectory.path}/application')
      ..createSync();
    _application = application;
    final rohd = Directory('${temporaryDirectory.path}/rohd')..createSync();
    Directory('${application.path}/lib').createSync();
    Directory('${rohd.path}/lib').createSync();
    File('${application.path}/pubspec.yaml').writeAsStringSync(
      'name: application\n'
      'environment:\n'
      "  sdk: '>=3.10.0 <4.0.0'\n",
    );
    File('${rohd.path}/lib/rohd.dart').writeAsStringSync('''
library rohd;

class Logic {
  Logic operator <(Logic other) => this;
}

class Conditional {}

class Combinational {
  static Combinational ssa(
    List<Conditional> Function(Logic Function(Logic) s) construct,
  ) => Combinational();
}
''');
    File(
      '${application.path}/.dart_tool/package_config.json',
    ).parent.createSync(recursive: true);
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

  test('reports a direct read before initialization', () async {
    final diagnostics = await _diagnostics('''
import 'package:rohd/rohd.dart';

void build(Logic input, Logic acc, Logic out) {
  Combinational.ssa((s) => [
    s(out) < s(acc),
    s(acc) < input,
  ]);
}
''');

    expect(diagnostics, hasLength(1));
    expect(diagnostics.single.offset, greaterThan(0));
  });

  test('accepts a value initialized before it is read', () async {
    expect(
      await _diagnostics('''
import 'package:rohd/rohd.dart';

void build(Logic input, Logic acc, Logic out) {
  Combinational.ssa((s) => [
    s(acc) < input,
    s(out) < s(acc),
  ]);
}
'''),
      isEmpty,
    );
  });

  test('ignores non-ROHD methods with the same name', () async {
    expect(
      await _diagnostics('''
class Logic {
  Logic operator <(Logic other) => this;
}

class Combinational {
  static Combinational ssa(
    List<Object> Function(Logic Function(Logic) s) construct,
  ) => Combinational();
}

void build(Logic input, Logic acc, Logic out) {
  Combinational.ssa((s) => [
    s(out) < s(acc),
    s(acc) < input,
  ]);
}
'''),
      isEmpty,
    );
  });
}

Future<List<_Diagnostic>> _diagnostics(String source) async {
  final path = '${_application.path}/lib/main.dart';
  File(path).writeAsStringSync(source);
  final collection = AnalysisContextCollection(
    includedPaths: [_application.path],
  );
  final result = await collection
      .contextFor(path)
      .currentSession
      .getResolvedUnit(path);
  expect(result, isA<ResolvedUnitResult>());
  final unit = (result as ResolvedUnitResult).unit;
  return findSsaReadBeforeWriteInvocations(
    unit,
  ).map((invocation) => _Diagnostic(invocation.offset)).toList();
}

class _Diagnostic {
  final int offset;

  _Diagnostic(this.offset);
}
