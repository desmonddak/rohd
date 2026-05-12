// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// signal_occurrence.dart
// A signal in the hardware occurrence hierarchy.
//
// 2026 May
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:meta/meta.dart';
import 'package:rohd_hierarchy/src/hierarchy_occurrence.dart';
import 'package:rohd_hierarchy/src/occurrence_address.dart';

/// Signals are the fundamental data carriers in hardware. A signal can be:
/// - An internal signal within an occurrence
/// - A port on an occurrence interface (has direction: input/output/inout)
///
/// This is a structural model without waveform data. Path strings are
/// computed on demand from the parent occurrence reference — call [path]
/// with your desired separator.
class SignalOccurrence {
  /// The name of the signal (bare name within its scope).
  ///
  /// Used for display, search, and local lookups within an occurrence.
  /// Not guaranteed unique across the full hierarchy — use [path] for
  /// unique keying.
  final String name;

  /// The bit width of the signal.
  final int width;

  /// Direction of the signal if it's a port.
  /// Null for internal signals.
  /// "input", "output", or "inout" for ports.
  final String? direction;

  /// Current runtime value of the signal (if available).
  /// Typically a hex or binary string representation.
  final String? value;

  /// Whether this signal's value is computed/derivable (e.g. constant,
  /// gate output, InlineSystemVerilog result) rather than directly tracked
  /// by the waveform service.
  final bool isComputed;

  /// Stable ordering index among ports in the parent occurrence.
  ///
  /// Set by the adapter that creates the signal.  For ports (signals with
  /// a [direction]), this records the deterministic position from the
  /// original source (netlist JSON iteration order, ROHD module port
  /// declaration order, etc.).  Internal signals have `null`.
  ///
  /// [HierarchyOccurrence.buildAddresses] places ports before internal
  /// signals when assigning [OccurrenceAddress] indices, so a port with
  /// `portIndex == k` will receive signal address index `k`.
  ///
  /// Consumers that store connectivity by `(nodeId, portIndex)` tuples
  /// (e.g. schematic hyperedges) rely on this value remaining stable
  /// across incremental hierarchy expansion.
  final int? portIndex;

  /// Hierarchical address for this signal. Assigned by
  /// [HierarchyOccurrence.buildAddresses] to enable efficient navigation.
  /// Format: [...occurrenceIndices, signalIndex]
  OccurrenceAddress? get address => _address;
  OccurrenceAddress? _address;

  /// Sets the address. Only for use by [HierarchyOccurrence.buildAddresses].
  @internal
  set address(OccurrenceAddress? value) => _address = value;

  /// Parent occurrence containing this signal. Set by
  /// [HierarchyOccurrence.buildAddresses].
  HierarchyOccurrence? get parent => _parent;
  HierarchyOccurrence? _parent;

  /// Sets the parent. Only for use by [HierarchyOccurrence.buildAddresses].
  @internal
  set parent(HierarchyOccurrence? value) => _parent = value;

  /// Creates a [SignalOccurrence] with the given properties.
  SignalOccurrence({
    required this.name,
    required this.width,
    this.direction,
    this.value,
    this.isComputed = false,
    this.portIndex,
  });

  /// Compute the full hierarchical path for this signal.
  ///
  /// Joins the parent occurrence's path with this signal's [name] using
  /// [separator].  Falls back to just [name] if parent is not yet set
  /// (e.g. in test fixtures before `buildAddresses`).
  String path({String separator = '/'}) {
    if (_parent == null) {
      return name;
    }
    return '${_parent!.path(separator: separator)}$separator$name';
  }

  /// Returns true if this signal is a port (has a direction).
  bool get isPort => direction != null;

  /// Returns true if this is an input port.
  bool get isInput => direction == 'input';

  /// Returns true if this is an output port.
  bool get isOutput => direction == 'output';

  /// Returns true if this is a bidirectional port.
  bool get isInout => direction == 'inout';

  @override
  String toString() => '$name (width=$width${isPort ? ', $direction' : ''})';
}
