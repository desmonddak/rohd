---
title: "Logic Arrays"
permalink: /docs/logic-arrays/
last_modified_at: 2022-6-5
toc: true
---

A [`LogicArray`](https://intel.github.io/rohd/rohd/LogicArray-class.html) is a type of `LogicStructure` that mirrors multi-dimensional arrays in hardware languages like SystemVerilog.  In ROHD, the `LogicArray` type inherits a lot of functionality from `LogicStructure`, so it can behave like a `Logic` where it makes sense or be individually referenced in other places.

`LogicArray`s can be constructed easily using the constructor:

```dart
// A 1D array with ten 8-bit elements.
LogicArray([10], 8);

// A 4x3 2D array, with four arrays, each with three 2-bit elements.
LogicArray([4, 3], 2, name: 'array4x3');

// A 5x5x5 3D array, with 125 total elements, each 128 bits.
LogicArray([5, 5, 5], 128);
```

As long as the total width of a `LogicArray` and another type of `Logic` (including `Logic`, `LogicStructure`, and another `LogicArray`) are the same, assignments and bitwise operations will work in per-element order.  This means you can assign two `LogicArray`s of different dimensions to each other as long as the total width matches.

## Unpacked arrays

In SystemVerilog, there is a concept of "packed" vs. "unpacked" arrays which have different use cases and capabilities. In ROHD, all arrays act the same and you get the best of both worlds.  You can indicate when constructing a `LogicArray` that some number of the dimensions should be "unpacked" as a hint to `Synthesizer`s. Marking an array with a non-zero `numUnpackedDimensions`, for example, will make that many of the dimensions "unpacked" in generated SystemVerilog signal declarations.

```dart
// A 4x3 2D array, with four arrays, each with three 2-bit elements.
// The first dimension (4) will be unpacked.
LogicArray(
  [4, 3],
  2,
  name: 'array4x3w1unpacked',
  numUnpackedDimensions: 1,
);
```

## Array ports

You can declare ports of `Module`s as being arrays (including with some dimensions "unpacked") using `addInputArray` and `addOutputArray`. Note that these do _not_ automatically do validation that the dimensions, element width, number of unpacked dimensions, etc. are equal between the port and the original signal. As long as the overall width matches, the assignment will be clean.

Array ports in generated SystemVerilog will match dimensions (including unpacked) as specified when the port is created.

## Elements of arrays

To iterate through or access elements of a `LogicArray` (or bits of a simple `Logic`), use [`elements`](https://intel.github.io/rohd/rohd/Logic/elements.html).  Using the normal `[n]` accessors will return the `n`th bit regardless for `LogicArray` and `Logic` to maintain API consistency.

## Index-based Selection in an Array

The [`selectIndex`](https://intel.github.io/rohd/rohd/IndexedLogic/selectIndex.html) and [`selectFrom`](https://intel.github.io/rohd/rohd/Logic/selectFrom.html) methods are used to select a value from a `LogicArray` or from a list of `Logic` elements based on an index. These methods are useful for creating dynamic selection logic in hardware design. They can be used in 2 ways as shown below.

### 1. Using a `LogicArray` type

```dart
final arrayA = LogicArray([4], 8, name: 'arrayA'); // A 1D array with four 8-bit element
final id = Logic(name: 'id', width: 3);

selectIndexValueArrayA <= arrayA.elements.selectIndex(id, defaultValue: defaultValue);
selectFromValueArrayA <= id.selectFrom(arrayA.elements, defaultValue: defaultValue);
```

An example code is given to demonstrate a usage of `selectIndex` and `selectFrom` for logic arrays.
Please see code here: [logic_array.dart](https://github.com/intel/rohd/blob/main/example/logic_array.dart)

### 2. Using a list of `Logic` elements

```dart
final inputA = Logic(name: 'inputA', width: 8);
final inputB = Logic(name: 'inputB', width: 8);
final inputC = Logic(name: 'inputC', width: 8);
final listA = <Logic>[inputA, inputB, inputC];

final id = Logic(name: 'id', width: 3);

selectIndexValueListA <= listA.selectIndex(id, defaultValue: defaultValue);
selectFromValueListA <= id.selectFrom(listA, defaultValue: defaultValue);
```
