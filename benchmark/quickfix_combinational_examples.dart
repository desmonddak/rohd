// Interactive assignment-ordering examples for regular, SSA, and sequential
// blocks.
//
// The regular examples exercise ROHD's runtime ordering behavior. The SSA
// examples exercise ROHD-S002 (ssa_read_before_write). They use local signals
// and registered ports so H001 does not obscure the relevant behavior.

import 'package:rohd/rohd.dart';

/// Regular Combinational: a signal is read before a later write.
///
/// ROHD's regular Combinational execution treats this as a write-after-read
/// hazard and can throw [WriteAfterReadException]. This is not ROHD-S002,
/// which only checks `Combinational.ssa`.
class RegularWriteAfterReadExample extends Module {
  RegularWriteAfterReadExample(Logic a, Logic b) {
    a = addInput('a', a);
    b = addInput('b', b);
    final result = addOutput('result');
    final intermediate = Logic(name: 'intermediate');

    Combinational([
      intermediate < a,
      result < intermediate ^ b,
      intermediate < 0,
    ]);
  }
}

/// Regular Combinational: the intermediate signal is written before it reads.
class RegularWriteBeforeReadExample extends Module {
  RegularWriteBeforeReadExample(Logic a, Logic b) {
    a = addInput('a', a);
    b = addInput('b', b);
    final result = addOutput('result');
    final intermediate = Logic(name: 'intermediate');

    Combinational([
      intermediate < a,
      intermediate < intermediate ^ b,
      result < intermediate,
    ]);
  }
}

/// SSA Combinational: an intermediate signal is read before initialization.
class SsaReadBeforeWriteExample extends Module {
  SsaReadBeforeWriteExample(Logic a, Logic b) {
    a = addInput('a', a);
    b = addInput('b', b);
    final result = addOutput('result');
    final intermediate = Logic(name: 'intermediate');

    Combinational.ssa((s) => [
          result < s(intermediate) ^ b,
          s(intermediate) < a,
        ]);
  }
}

/// SSA Combinational: every remapped signal is initialized before it is read.
class SsaWriteBeforeReadExample extends Module {
  SsaWriteBeforeReadExample(Logic a, Logic b) {
    a = addInput('a', a);
    b = addInput('b', b);
    final result = addOutput('result');
    final intermediate = Logic(name: 'intermediate');

    Combinational.ssa((s) => [
          s(intermediate) < a,
          result < s(intermediate) ^ b,
        ]);
  }
}

/// Sequential logic where the result intentionally observes the old state.
///
/// This is legal sequential behavior: both assignments occur on the same
/// clock edge, and the output receives the previous state value.
class SequentialOldStateExample extends Module {
  SequentialOldStateExample(Logic clk, Logic data) {
    clk = addInput('clk', clk);
    data = addInput('data', data);
    final result = addOutput('result');
    final state = Logic(name: 'state');
    state <= Logic();
  state <= Logic();
    Sequential(clk, [
      state < data,
      result < state,
    ]);
  }
}

/// Sequential logic with explicit next-state ordering.
class SequentialNextStateExample extends Module 
{
  SequentialNextStateExample(Logic clk, Logic data) {
    clk = addInput('clk', clk);
    data = addInput('data', data);
    final result = addOutput('result');
    final nextState = Logic(name: 'nextState');

    Combinational([
      nextState < data,
    ]);
    Sequential(clk, [
      result < nextState,
    ]);
  }
}
