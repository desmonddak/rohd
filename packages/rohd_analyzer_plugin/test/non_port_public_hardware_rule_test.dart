// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:rohd_analyzer_plugin/src/non_port_public_hardware_fix.dart';
import 'package:rohd_analyzer_plugin/src/non_port_public_hardware_rule.dart';
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
  int get width => 1;
  Logic named(String name) => this;
  Logic operator [](int index) => this;
}

extension LogicListExtensions on List<Logic> {
  Logic rswizzle() => Logic();
}

class Const extends Logic {}

class SimpleClockGenerator {
  SimpleClockGenerator(int period);
  Logic get clk => Logic();
}

class LogicArray extends Logic {
  LogicArray(
    [
      List<int> dimensions = const [],
      int elementWidth = 1,
    ], {
    String? name,
  });
  List<Logic> get elements => [];
}

class LogicNet extends Logic {}

class LogicStructure extends Logic {
  LogicStructure({String? name});
  Logic get valid => this;
}

class Interface {
  Logic get dataOut => Logic();

  void connectIO(Module module, Interface source) {}
}

class Module {
  Logic addInput(String name, Logic signal, {int? width}) => signal;
  Logic addTypedInput(String name, Logic signal) => signal;
  LogicArray addInputArray(
    String name,
    Logic signal, {
    List<int> dimensions = const [1],
    int elementWidth = 1,
  }) =>
      LogicArray();
  Logic addOutput(String name, {int? width}) => Logic();
  Logic output(String name) => Logic();
  Logic inputSource(String name) => Logic();
  LogicNet addInOut(String name, LogicNet source, {int? width}) => source;
  Logic inOut(String name) => LogicNet();
  Logic inOutSource(String name) => LogicNet();
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
    'handles a same-name constructor assignment without recursion',
    () async {
      final diagnostics = await _diagnostics(application, '''
import 'package:rohd/rohd.dart';

class Passthrough extends Module {
  late final Logic signal;

  Passthrough(Logic signal) {
    this.signal = signal;
  }
}
''');

      expect(
        diagnostics.map(
          (diagnostic) => diagnostic.diagnosticCode.lowerCaseName,
        ),
        [NonPortPublicHardwareRule.code.lowerCaseName],
      );
    },
  );

  test('finds a local port through a cyclic assignment graph', () async {
    final diagnostics = await _diagnostics(application, '''
import 'package:rohd/rohd.dart';

class CyclicAliases extends Module {
  late Logic first;
  late Logic second;

  CyclicAliases(Logic signal) {
    first = second;
    second = first;
    second = addInput('signal', signal);
  }
}
''');

    expect(diagnostics, isEmpty);
  });

  test('accepts an interface member connected as local module ports', () async {
    final diagnostics = await _diagnostics(application, '''
import 'package:rohd/rohd.dart';

class FilterDataInterface extends Interface {}

class FilterChannel extends Module {
  late final FilterDataInterface intf;

  Logic get dataOut => intf.dataOut;

  FilterChannel(FilterDataInterface source) {
    intf = FilterDataInterface()..connectIO(this, source);
  }
}
''');

    expect(diagnostics, isEmpty);
  });

  test('accepts a getter accessing a registered port getter', () async {
    final diagnostics = await _diagnostics(application, '''
import 'package:rohd/rohd.dart';

class FilterBank extends Module {
  LogicArray get channelOut => output('channelOut') as LogicArray;

  Logic get out0 => channelOut[0];

  LogicStructure get status => output('status') as LogicStructure;

  Logic get validOut => status.valid;
}
''');

    expect(diagnostics, isEmpty);
  });

  test('accepts a getter accessing a registered inout port', () async {
    final diagnostics = await _diagnostics(application, '''
import 'package:rohd/rohd.dart';

class TriStateBuffer extends Module {
  LogicNet get out => inOutSource('out') as LogicNet;
}
''');

    expect(diagnostics, isEmpty);
  });

  test('accepts constant-generated hardware without a port', () async {
    final diagnostics = await _diagnostics(application, '''
import 'package:rohd/rohd.dart';

class ConstAliasModule extends Module {
  late final Const constant = Const();
  late final Logic alias = constant.named('alias');

  ConstAliasModule() {
    addOutput('out') <= alias;
  }
}
''');

    expect(diagnostics, isEmpty);
  });

  test('offers @protected for an internal-only hardware collection', () async {
    const source = '''
import 'package:rohd/rohd.dart';

class _InternalMemory extends Module {
  _InternalMemory() {
    memory = <Logic>[];
    memory.add(Logic());
  }

  late final List<Logic> memory;
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(1));

    final result = await _resolvedUnit(application);
    final diagnostic = diagnostics.single;
    expect(
      nonPortPublicHardwareProtectedFixAnnotation(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      '@protected\n  ',
    );
    expect(
      NonPortPublicHardwareFix.protectedKind.message,
      'Make field protected because it is not used outside its class',
    );
  });

  test('offers a registered output array for a populated Logic list', () async {
    const source = '''
import 'package:rohd/rohd.dart';

class NBitAdder extends Module {
  final sum = <Logic>[];

  NBitAdder() {
    final n = 2;
    for (var i = 0; i < n; i++) {
      sum.add(Logic());
    }
    sum.add(Logic());
  }
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(1));

    final result = await _resolvedUnit(application);
    final diagnostic = diagnostics.single;
    expect(
      nonPortPublicHardwareLeafListFixAvailable(
        await _resolvedUnit(application),
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isFalse,
    );
    expect(
      nonPortPublicHardwareArrayFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isTrue,
    );
    expect(
      NonPortPublicHardwareFix.arrayOutputKind.message,
      'Convert List<Logic> field to a registered output array',
    );
  });

  test('offers leaf outputs for a list consumed by rswizzle', () async {
    const source = '''
import 'package:rohd/rohd.dart';

class NBitAdder extends Module {
  final sum = <Logic>[];

  NBitAdder() {
    final n = 2;
    for (var i = 0; i < n; i++) {
      sum.add(Logic());
    }
    sum.add(Logic());
    sum.rswizzle();
  }
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(1));

    final result = await _resolvedUnit(application);
    final diagnostic = diagnostics.single;
    expect(
      nonPortPublicHardwareLeafListFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isTrue,
    );
    expect(
      nonPortPublicHardwareArrayFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isFalse,
    );
  });

  test('offers leaf outputs for the tutorial NBitAdder list', () async {
    const source = '''
import 'package:rohd/rohd.dart';

class FullAdderResult {
  final sum = Logic();
  final cOut = Logic();
}

class FullAdder extends Module {
  FullAdder({required Logic a, required Logic b, required Logic carryIn});

  FullAdderResult get fullAdderRes => FullAdderResult();
}

class NBitAdder extends Module {
  final sum = <Logic>[];
  Logic carry = Const(0);
  Logic a;
  Logic b;

  NBitAdder(this.a, this.b) {
    a = addInput('a', a, width: a.width);
    b = addInput('b', b, width: b.width);
    carry = addInput('carry_in', carry, width: carry.width);
    final n = a.width;

    for (var i = 0; i < n; i++) {
      final res = FullAdder(a: a[i], b: b[i], carryIn: carry);
      carry = res.fullAdderRes.cOut;
      sum.add(res.fullAdderRes.sum);
    }
    sum.add(carry);
  }

  LogicValue get sumRes => sum.rswizzle().value;
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(1));

    final result = await _resolvedUnit(application);
    final diagnostic = diagnostics.single;
    expect(
      nonPortPublicHardwareLeafListFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isTrue,
    );
  });

  test(
    'accepts a getter backed by individually registered list leaves',
    () async {
      const source = '''
import 'package:rohd/rohd.dart';

class RegisteredListModule extends Module {
  late final List<Logic> _sum;
  List<Logic> get sum => _sum;

  RegisteredListModule() {
    _sum = <Logic>[];
    _sum.add(addOutput('sum_0'));
    _sum.add(addOutput('sum_1'));
  }
}
''';
      expect(await _diagnostics(application, source), isEmpty);
    },
  );

  test('offers typed input accessors for structure and array fields', () async {
    const source = '''
import 'package:rohd/rohd.dart';

class TypedInputs extends Module {
  late final LogicStructure structPort;
  late final LogicArray arrayPort;

  TypedInputs() {
      structPort = LogicStructure(name: 'struct');
      addInput('struct_in', structPort, width: structPort.width);
      arrayPort = LogicArray();
      addInputArray('array_in', arrayPort, dimensions: [2], elementWidth: 1);
  }
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(2));

    final result = await _resolvedUnit(application);
    for (final diagnostic in diagnostics) {
      expect(
        nonPortPublicHardwareInputFixAvailable(
          result,
          offset: diagnostic.problemMessage.offset,
          length: diagnostic.problemMessage.length,
        ),
        isTrue,
      );
    }
    final diagnostic = diagnostics.first;
    final libraryResult = await result.session.getResolvedLibrary(result.path);
    expect(libraryResult, isA<ResolvedLibraryResult>());
    final context = CorrectionProducerContext.createResolved(
      libraryResult: libraryResult as ResolvedLibraryResult,
      unitResult: result,
      diagnostic: diagnostic,
      selectionOffset: diagnostic.problemMessage.offset,
      selectionLength: diagnostic.problemMessage.length,
    );
    final builder = ChangeBuilder(session: result.session, defaultEol: '\n');
    await NonPortPublicHardwareInputFix(context: context).compute(builder);
    final fileEdit = builder.sourceChange.edits.single;
    final editedSource = SourceEdit.applySequence(source, fileEdit.edits);
    expect(
      editedSource,
      contains(
        "LogicStructure get structPort => inputSource('struct_in') "
        'as LogicStructure;',
      ),
    );
    expect(editedSource, contains('final structPort = LogicStructure('));
    expect(editedSource, isNot(contains(';;')));
    expect(
      editedSource,
      isNot(contains('late final LogicStructure structPort;')),
    );
    expect(
      NonPortPublicHardwareFix.inputKind.message,
      'Convert field to a registered input accessor',
    );
  });

  test('offers a registered inout for a LogicNet field', () async {
    const source = '''
import 'package:rohd/rohd.dart';

class TriStateBuffer extends Module {
  late final String _outName;
  late final LogicNet out;

  TriStateBuffer() {
    _outName = 'out';
    out = LogicNet();
    addInOut(_outName, out, width: 1);
  }
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(1));

    final result = await _resolvedUnit(application);
    final diagnostic = diagnostics.single;
    expect(
      nonPortPublicHardwareInOutFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isTrue,
    );
    expect(
      NonPortPublicHardwareFix.inOutKind.message,
      'Convert field to a registered inout port',
    );
  });

  test('prioritizes inout for a LogicNet assigned through addInOut', () async {
    const source = '''
import 'package:rohd/rohd.dart';

class TriStateBuffer extends Module {
  late final String _outName;
  late final LogicNet out;
  final Logic _outDriver = Logic();

  TriStateBuffer() {
    _outName = 'out';
    out = LogicNet();
    addInOut(_outName, out, width: 1) <= _outDriver;
  }
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(1));

    final result = await _resolvedUnit(application);
    final diagnostic = diagnostics.single;
    expect(
      nonPortPublicHardwareInOutFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isTrue,
    );
    expect(
      nonPortPublicHardwareOutputFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isFalse,
    );
  });

  test('offers a registered output for an initialized Logic field', () async {
    const source = '''
import 'package:rohd/rohd.dart';

class BadSubModuleOut extends Module {
  final Logic y = Logic(name: 'y');

  BadSubModuleOut(Logic a) {
    y <= a;
  }
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(1));

    final result = await _resolvedUnit(application);
    final diagnostic = diagnostics.single;
    expect(
      nonPortPublicHardwareOutputFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isTrue,
    );
  });

  test('offers an output for a cascaded Logic drive', () async {
    const source = '''
import 'package:rohd/rohd.dart';

class NamingCase extends Module {
  late final Logic reservedInternal;

  NamingCase(Logic input) {
    reservedInternal =
        Logic(name: 'resv', width: 8, naming: Naming.reserved)
          ..gets(input);
  }
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(1));

    final result = await _resolvedUnit(application);
    final diagnostic = diagnostics.single;
    expect(
      nonPortPublicHardwareOutputFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isTrue,
    );
  });

  test('offers an output for an internally generated clock field', () async {
    const source = '''
import 'package:rohd/rohd.dart';

class TestBench extends Module {
  final Logic clk = SimpleClockGenerator(10).clk;

  TestBench() {
    final value = clk;
  }
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(1));

    final result = await _resolvedUnit(application);
    final diagnostic = diagnostics.single;
    expect(
      nonPortPublicHardwareInitializedOutputFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isTrue,
    );
  });

  test('offers registered outputs for a generated Logic list', () async {
    const source = r'''
import 'package:rohd/rohd.dart';

class CarrySaveMultiplier extends Module {
  final List<Logic> sum =
      List.generate(8, (index) => Logic(name: 'sum_$index'));

  CarrySaveMultiplier() {
    sum[0] <= Logic();
  }
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(1));

    final result = await _resolvedUnit(application);
    final diagnostic = diagnostics.single;
    expect(
      nonPortPublicHardwareGeneratedListFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isTrue,
    );
  });

  test('offers typed outputs for a generated LogicStructure list', () async {
    const source = r'''
import 'package:rohd/rohd.dart';

class StructureBank extends Module {
  final List<LogicStructure> values =
      List.generate(4, (index) => LogicStructure(name: 'value_$index'));

  StructureBank() {
    values[0] <= LogicStructure();
  }
}
''';
    final diagnostics = await _diagnostics(application, source);
    expect(diagnostics, hasLength(1));

    final result = await _resolvedUnit(application);
    final diagnostic = diagnostics.single;
    expect(
      nonPortPublicHardwareGeneratedListFixAvailable(
        result,
        offset: diagnostic.problemMessage.offset,
        length: diagnostic.problemMessage.length,
      ),
      isTrue,
    );
  });
}

Future<List<Diagnostic>> _diagnostics(
  Directory application,
  String source,
) async {
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

  final listener = _CollectingDiagnosticListener();
  final rule = NonPortPublicHardwareRule()
    ..reporter = DiagnosticReporter(listener, unit.declaredFragment!.source);
  final registry = _ClassDeclarationRegistry();
  rule.registerNodeProcessors(registry, _UnusedRuleContext());

  final visitor = registry.visitor;
  expect(visitor, isNotNull);
  for (final declaration in unit.declarations.whereType<ClassDeclaration>()) {
    declaration.accept(visitor!);
  }
  return listener.diagnostics;
}

Future<ResolvedUnitResult> _resolvedUnit(Directory application) async {
  final path = '${application.path}/lib/main.dart';
  final collection = AnalysisContextCollection(
    includedPaths: [application.path],
  );
  final result = await collection
      .contextFor(path)
      .currentSession
      .getResolvedUnit(path);
  expect(result, isA<ResolvedUnitResult>());
  return result as ResolvedUnitResult;
}

class _ClassDeclarationRegistry implements RuleVisitorRegistry {
  AstVisitor<void>? visitor;

  @override
  void addClassDeclaration(
    AbstractAnalysisRule rule,
    AstVisitor<void> visitor,
  ) {
    this.visitor = visitor;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedRuleContext implements RuleContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CollectingDiagnosticListener implements DiagnosticListener {
  final diagnostics = <Diagnostic>[];

  @override
  void onDiagnostic(Diagnostic diagnostic) {
    diagnostics.add(diagnostic);
  }
}
