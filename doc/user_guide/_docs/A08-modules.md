---
title: "Modules"
permalink: /docs/modules/
excerpt: "Modules"
last_modified_at: 2025-7-24
toc: true
---

[`Module`](https://intel.github.io/rohd/rohd/Module-class.html)s are similar to modules in SystemVerilog.  They have inputs and outputs and logic that connects them.  There are a handful of rules that *must* be followed when implementing a module.

1. Inputs and inOuts (from `input`, `addInput`, `inOut` or `addInOut` methods, or their array and match equivalents) return *internal* copies of ports that should be used inside a `Module`.  Signals should not be consumed directly from outside a `Module`.  Internal module logic should consume the internal versions.  Logic outside the `Module` can drive to (or receive from, in the case of inOut) that `Module` only through the external copies, i.e. arguments passed to `addInput`, `addInOut`, etc.
2. Outputs (from `output` or `addOutput`, or their array and match equivalents) are the only way logic outside of a `Module` can consume signals from that `Module`.  There are no internal vs. external versions of `output`s, so they may be consumed inside of `Module`s as well.
3. All logic must be defined *before* the call to `super.build()`.  Logic should not be further defined after build.

The reasons for these rules have to do with how ROHD is able to determine which logic and `Module`s exist within a given Module and how ROHD builds connectivity.  If these rules are not followed, generated outputs (including waveforms and SystemVerilog) may be unpredictable.

You should strive to build logic within the constructor of your `Module` (directly or via method calls within the constructor).  This way any code can utilize your `Module` immediately after creating it.  **Be careful** to consume the registered `input`s and drive the registered `output`s of your module, and not the "raw" external arguments passed to the constructor.

It is legal to put logic within an override of the `build` function, but that forces users of your module to always call `build` before it will be functionally usable for simple simulation.  If you put logic in `build()`, ensure you put the call to `super.build()` *at the end* of the method.

Note that the `build()` method returns a `Future<void>`, not just `void`.  This is because the `build()` method is permitted to consume real wall clock time in some cases, for example for setting up cosimulation with another simulator.  Make sure the `build` completes before the simulation begins.

It is not necessary to put all logic directly within a class that extends Module.  You can put synthesizable logic in other functions and classes, as long as the logic eventually connects to an input or output of a module if you hope to convert it to SystemVerilog.  Except where there is a desire for the debug hierarchy, waveforms, SystemVerilog generated, etc. to have equivalent module hierarchy, it is not necessary to use submodules within modules instead of plain classes or functions.

The `Module` base class has an optional String argument `name` which is an instance name.  There are also options for the `definitionName` and reservation of both names, which can be especially useful to control generation of outputs like SystemVerilog.

`Module`s have the below basic structure:

```dart
// class must extend Module to be a Module
class MyModule extends Module {
    
    // constructor
    MyModule(Logic in1) {
        // add inputs in the constructor, passing in the Logic it is connected to
        // it's a good idea to re-set the input parameters, 
        // so you don't accidentally use the wrong one
        in1 = addInput('in1', in1);

        // add outputs in the constructor as well
        // you can capture the output variable to a local variable for use
        var out = addOutput('out');

        // now you can define your logic
        // this example is just a passthrough from 'in1' to 'out'
        out <= in1;
    }
}
```

All gates or functionality apart from assign statements in ROHD are implemented using Modules.

#### Ports, widths, and getters

The default width of a port is 1.  You can control the width of ports using the `width` argument of `addInput()` and `addOutput()`.  You may choose to set them to a static number, based on some other variable, or even dynamically based on the width of input parameters.  These functions also return the input/output signal.

There are also similar functions called `addTypedInput` and `addTypedOutput` which will create a port with matching widths and types.  This is especially useful for creating `LogicStructure` ports.

Available mechanisms for creating ports on a `Module` are listed below:

| API                | Description                                                                                                      |
|--------------------|------------------------------------------------------------------------------------------------------------------|
| `addTypedInput`    | Adds an input port (of any `Logic` type including `LogicArray` and `LogicStructure`) with width/dimensions and type matched to another signal. Requires an external source. |
| `addInput`         | Adds an input `Logic` port to the module with explicit width. Requires an external source. |
| `addInputArray`    | Adds an input `LogicArray` port to the module with explicit dimensions and element width. Requires an external source. |
| `addTypedOutput`   | Adds an output port (of any `Logic` type including `LogicArray` and `LogicStructure`) with width/dimensions and type generated. Requires a generator. |
| `addOutput`        | Adds an output `Logic` port to the module with explicit width. |
| `addOutputArray`   | Adds an output `LogicArray` port to the module with explicit dimensions and element width. |
| `addTypedInOut`    | Adds an in/out port (of any `Logic` type including `LogicArray` and `LogicStructure`) with width/dimensions and type matched to another signal. Requires an external source. |
| `addInOut`         | Adds an in/out (bidirectional) `Logic` port to the module with explicit width. Requires an external source. |
| `addInOutArray`    | Adds an in/out (bidirectional) `LogicArray` port to the module with explicit dimensions and element width. Requires an external source. |

You can also use [`Interface`s](https://intel.github.io/rohd-website/docs/interfaces/) to create groups of ports.

It can be convenient to use dart getters for signal names so that accessing inputs and outputs of a module doesn't require calling `input()` and `output()` every time.  It also makes it easier to consume your module.

Below are some examples of inputs and outputs in a Module.

```dart
class MyModule extends Module {

    MyModule(Logic a, Logic b, Logic c, Logic d, {int xWidth=5}) {
        
        // 'a' should always be width 4, throw an exception if its wrong
        if(a.width != 4) throw Exception('Width of a must be 4!');
        addInput('a', a, width: 4);

        // allow 'b' to always be any width, based on what's passed in
        addInput('b', b, width: b.width);

        // default width is 1, so 'c' is 1 bit
        // addInput returns the value of input('c'), if you want it
        var c_input = addInput('c', c)

        // create a port 'b' with the same width as whatever was received
        addTypedInput('d', d);

        // set the width of 'x' based on the constructor argument
        addOutput('x', width: xWidth);

        // you can dynamically set the output width based on an input width, 
        // as well addOutput returns the value of output('y'), if you want it
        var y_output = addOutput('y', width: b.width);

        // create an output 'z' that has the same width and type as 'd'.
        addTypedOutput('z', d.clone);
    }

    // A verbose getter of the value of input 'a'.
    Logic get a {
      return input('a');
    }
    
    // Dart shorthand makes getters less verbose, 
    // but the functionality is the same as above
    Logic get b => input('b');
    Logic get x => output('x');
    Logic get y => output('y');

    // it is not necessary to have all signals accessible through getters, 
    // here we omit 'c'

}
```

For `LogicArray`s, you can create `LogicArray` ports.  See [the section on Logic Arrays](https://intel.github.io/rohd-website/docs/logic-arrays/) for more details.

For `LogicNet`s, you can create `inOut` ports.  See [the section on Logic Nets, In/Outs, and Tri-state Buffers](https://intel.github.io/rohd-website/docs/logic-nets/) for more details.
