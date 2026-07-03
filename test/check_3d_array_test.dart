import 'dart:convert';
import 'dart:io';
import 'package:rohd/rohd.dart';

/// Leaf that just passes through.
class Leaf8 extends Module {
  Leaf8(Logic inp, {required super.name}) {
    final i = addInput('i', inp, width: 8);
    addOutput('o', width: 8) <= i;
  }
}

/// Module with 3D array input where elements are used DIRECTLY in logic
/// (not each through a sub-module). Has one sub-module to ensure synthesis.
class Inner3DDirect extends Module {
  Inner3DDirect(Logic src) : super(name: 'Inner3DDirect') {
    final inp = addInputArray(
      'data',
      src,
      dimensions: [2, 3, 4],
      elementWidth: 8,
    );
    // Use ONE element through a sub-module (to force synthesis)
    final leaf = Leaf8(inp.elements[0].elements[0].elements[0], name: 'leaf');
    // Use all other elements directly via XOR (no sub-module per element)
    var result = leaf.output('o');
    for (var i = 0; i < 2; i++) {
      for (var j = 0; j < 3; j++) {
        for (var k = 0; k < 4; k++) {
          if (i == 0 && j == 0 && k == 0) {
            continue; // already used
          }
          result = result ^ inp.elements[i].elements[j].elements[k];
        }
      }
    }
    addOutput('out', width: 8) <= result;
  }
}

/// Top wrapper.
class TopDirect extends Module {
  TopDirect() : super(name: 'TopDirect') {
    final src = LogicArray([2, 3, 4], 8, name: 'dataSrc');
    final inp = addInputArray(
      'data',
      src,
      dimensions: [2, 3, 4],
      elementWidth: 8,
    );
    final inner = Inner3DDirect(inp);
    addOutput('out', width: 8) <= inner.output('out');
  }
}

Future<void> main() async {
  try {
    final m = TopDirect();
    await m.build();

    final ns = NetlistService(m);
    final full = jsonDecode(ns.json) as Map<String, dynamic>;
    final modules = full['modules'] as Map<String, dynamic>;

    final inner = modules['Inner3DDirect'] as Map<String, dynamic>?;
    if (inner == null) {
      stdout.writeln('ERROR: Inner3DDirect not found!');
      return;
    }

    final nn = inner['netnames'] as Map<String, dynamic>? ?? {};
    final ports = inner['ports'] as Map<String, dynamic>? ?? {};
    final cells = inner['cells'] as Map<String, dynamic>? ?? {};

    // Build index exactly like evaluator does
    final bitToSig = <int, String>{};
    final sigBits = <String, List<int>>{};

    void regBits(String name, List<dynamic> bits) {
      final intBits = <int>[];
      for (final b in bits) {
        if (b is int) {
          bitToSig.putIfAbsent(b, () => name);
          intBits.add(b);
        }
      }
      if (intBits.isNotEmpty) {
        sigBits[name] = intBits;
      }
    }

    for (final e in ports.entries) {
      regBits(e.key, (e.value as Map<String, dynamic>)['bits'] as List? ?? []);
    }
    for (final e in nn.entries) {
      regBits(e.key, (e.value as Map<String, dynamic>)['bits'] as List? ?? []);
    }

    // Build driver map (all cell types, not just $slice)
    final driverOf = <String, String>{};
    for (final cellEntry in cells.entries) {
      final cellName = cellEntry.key;
      final cellData = cellEntry.value as Map<String, dynamic>;
      final conns = cellData['connections'] as Map<String, dynamic>? ?? {};
      final pDirs = cellData['port_directions'] as Map<String, dynamic>? ?? {};
      for (final pName in pDirs.keys) {
        if (pDirs[pName] != 'output') {
          continue;
        }
        final bits = conns[pName] as List? ?? [];
        final outSigs = <String>{};
        for (final b in bits) {
          if (b is int) {
            final sig = bitToSig[b];
            if (sig != null) {
              outSigs.add(sig);
            }
          }
        }
        for (final sig in outSigs) {
          if (!driverOf.containsKey(sig)) {
            driverOf[sig] = '$cellName (${cellData["type"]})';
          }
        }
      }
    }

    // Check all data_* signals
    final dataSignals = <String>{};
    for (final k in ports.keys) {
      if (k.contains('data')) {
        dataSignals.add(k);
      }
    }
    for (final k in nn.keys) {
      if (k.contains('data')) {
        dataSignals.add(k);
      }
    }
    final sorted = dataSignals.toList()..sort();

    var failCount = 0;
    for (final name in sorted) {
      final bits = sigBits[name];
      if (bits == null) {
        stdout.writeln('  $name: NOT IN sigBits [FAIL]');
        failCount++;
        continue;
      }
      if (ports.containsKey(name)) {
        continue; // ports are fine
      }
      if (driverOf.containsKey(name)) {
        continue; // has a driver
      }
      // Wire alias check
      String? aliasName;
      for (final b in bits) {
        final traceSig = bitToSig[b];
        if (traceSig != null && traceSig != name) {
          aliasName = traceSig;
          break;
        }
      }
      if (aliasName == null) {
        stderr.writeln('  $name (${bits.length}b): NO ALIAS! [FAIL]');
        failCount++;
      }
    }

    if (failCount > 0) {
      stderr.writeln(r'\nFailed signals share bits with themselves only.');
      exitCode = 1;
    }
    // ignore: avoid_catches_without_on_clauses
  } catch (e, st) {
    stderr
      ..writeln('ERROR: $e')
      ..writeln(st);
  }
}
