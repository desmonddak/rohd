// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// waveform_service.dart
// Service for exposing waveform data to DevTools via VM Service protocol.
// Parallel to ModuleTree for hierarchy data.
//
// 2026 January
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:rohd/rohd.dart';
import 'package:rohd/src/utilities/uniquifier.dart';

/// Represents a single value change for a signal.
class ValueChange {
  /// The simulation time of the change.
  final int time;

  /// The new value (as a string, e.g., '0', '1', 'x', '0xFF').
  final String value;

  /// Creates a value change record.
  ValueChange({required this.time, required this.value});

  /// Converts to JSON map.
  Map<String, dynamic> toJson() => {'time': time, 'value': value};
}

/// Represents metadata for a signal being tracked.
class TrackedSignal {
  /// Unique identifier (hierarchical path).
  final String id;

  /// Signal name.
  final String name;

  /// Bit width.
  final int width;

  /// Parent scope ID.
  final String scopeId;

  /// Full hierarchical path.
  final String fullPath;

  /// Direction ('input', 'output', or 'internal').
  final String direction;

  /// Creates tracked signal metadata.
  TrackedSignal({
    required this.id,
    required this.name,
    required this.width,
    required this.scopeId,
    required this.fullPath,
    this.direction = 'internal',
  });

  /// Converts to JSON map.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'width': width,
        'scopeId': scopeId,
        'fullPath': fullPath,
        'direction': direction,
        'type': 'logic',
      };
}

/// `WaveformDataService` implements the Singleton design pattern to track
/// signal value changes during simulation for DevTools inspection.
///
/// This works in parallel with `ModuleTree` for hierarchy data. While
/// ModuleTree provides the structure, WaveformDataService provides the
/// time-series signal values.
///
/// ## Usage
///
/// The service is automatically populated by the DevTools-streaming
/// [WaveformService] subclass (constructed with
/// `enableDevToolsStreaming: true`). Alternatively, you can manually record
/// value changes:
///
/// ```dart
/// // Initialize with a module
/// WaveformDataService.init(myModule);
///
/// // Record a value change
/// WaveformDataService.instance.recordChange('top/clk', 100, '1');
///
/// // Query data from DevTools via VM service evaluate()
/// final json =
///          WaveformDataService.instance.getWaveformsJSON(['top/clk'], 0, 1000);
/// ```
class WaveformDataService {
  /// Private constructor for singleton.
  WaveformDataService._();

  /// Singleton instance.
  static WaveformDataService get instance => _instance;
  static final _instance = WaveformDataService._();

  /// The root module being tracked (optional, for structure).
  Module? _rootModule;

  /// Current simulation time (updated on each value change).
  int _currentTime = 0;

  /// Map of signal ID to list of value changes.
  final Map<String, List<ValueChange>> _signalData = {};

  /// Map of signal ID to signal metadata.
  final Map<String, TrackedSignal> _signalMetadata = {};

  /// Map of Logic objects to their signal IDs for fast lookup.
  final Map<Logic, String> _logicToIdMap = {};

  /// Integer index for each signal ID, enabling compact (int-keyed) transport.
  ///
  /// Built during [_collectSignals]. The reverse lookup is done via
  /// [_signalIndexReverse].  Using integer keys in JSON reduces payload size
  /// by ~88% and string object allocations by ~80%, dramatically lowering
  /// GC pressure on both producer and consumer.
  final Map<String, int> _signalIndex = {};

  /// Reverse map: integer index → signal ID.
  final Map<int, String> _signalIndexReverse = {};

  // ─── FST-backed storage (Phase 2) ────────────────────────────────────
  //
  // When an FstWriter is attached, historical signal data lives on disk
  // in flushed VcData blocks.  WaveformDataService only keeps unflushed data
  // (the "hot buffer") in memory, dramatically reducing memory usage for
  // long simulations.
  //
  // For VCD mode (no FstWriter attached), the full in-memory cache in
  // [_signalData] is used as before.

  /// The attached FST writer, or null for VCD mode.
  FstWriter? _fstWriter;

  /// The block reader (created when [_fstWriter] is attached).
  FstBlockReader? _fstBlockReader;

  /// Mapping from WaveformDataService signal ID → FST handle index (0-based).
  final Map<String, int> _signalIdToFstHandle = {};

  /// Reverse mapping: FST handle index (0-based) → signal ID.
  final Map<int, String> _fstHandleToSignalId = {};

  /// Whether FST-backed disk storage is active.
  bool get isFstBacked => _fstWriter != null;

  /// Attach an [FstWriter] for FST-backed disk storage.
  ///
  /// When attached, [recordChange] stores data only in the writer's
  /// hot buffer instead of the unbounded in-memory [_signalData] map.
  /// Historical data is read back from flushed VcData blocks on demand.
  ///
  /// [logicToHandle] maps each Logic to its FST signal handle, enabling
  /// the service to route queries to the correct disk-backed signal.
  void attachFstWriter(
      FstWriter writer, Map<Logic, FstSignalHandle> logicToHandle) {
    _fstWriter = writer;
    _fstBlockReader = FstBlockReader(writer.filePath, writer.signalInfoList);

    // Build the signal ID ↔ FST handle mapping
    _signalIdToFstHandle.clear();
    _fstHandleToSignalId.clear();
    for (final entry in logicToHandle.entries) {
      final signalId = _logicToIdMap[entry.key];
      if (signalId != null) {
        final handleIdx = entry.value.handle - 1; // 0-based
        _signalIdToFstHandle[signalId] = handleIdx;
        _fstHandleToSignalId[handleIdx] = signalId;
      }
    }
  }

  /// Whether the service has been initialized.
  bool get isInitialized => _rootModule != null || _signalMetadata.isNotEmpty;

  /// Current simulation time.
  int get currentTime => _currentTime;

  /// Number of signals being tracked.
  int get signalCount => _signalMetadata.length;

  /// Total number of value changes recorded.
  int get totalValueChanges =>
      _signalData.values.fold(0, (sum, list) => sum + list.length);

  /// Initialize the service with a module hierarchy.
  ///
  /// This registers all signals in the module tree for tracking,
  /// and registers VM service extensions for fast DevTools communication.
  /// Call this after the module is built.
  static void init(Module module) {
    instance._rootModule = module;
    instance
      .._collectSignals(module)
      .._registerServiceExtensions();
  }

  /// Whether [startRecording] has already attached change listeners.
  bool _recordingStarted = false;

  /// Records current values and subscribes to future changes for tracked logic.
  void startRecording() {
    if (_recordingStarted) {
      return;
    }
    _recordingStarted = true;
    for (final logic in _logicToIdMap.keys) {
      recordLogicChange(logic, Simulator.time);
      logic.changed.listen((_) => recordLogicChange(logic, Simulator.time));
    }
  }

  /// Clear all recorded data and reset the service.
  void clear() {
    _signalData.clear();
    _signalMetadata.clear();
    _logicToIdMap.clear();
    _signalIndex.clear();
    _signalIndexReverse.clear();
    _signalIdToFstHandle.clear();
    _fstHandleToSignalId.clear();
    _fstWriter = null;
    _fstBlockReader = null;
    _recordingStarted = false;
    _currentTime = 0;
    _rootModule = null;
  }

  /// Whether service extensions have already been registered.
  bool _extensionsRegistered = false;

  /// Register VM service extensions for fast DevTools communication.
  ///
  /// Service extensions use `callServiceExtension()` instead of `evaluate()`,
  /// which avoids the ~650ms evaluate() overhead.  The extension names follow
  /// the `ext.rohd.*` convention so they are clearly namespaced.
  ///
  /// Registered extensions:
  /// - `ext.rohd.waveformStructure` — module/signal structure (no params)
  /// - `ext.rohd.waveformData` — waveform data in time range
  /// - `ext.rohd.waveformDataSince` — incremental data since a time
  /// - `ext.rohd.waveformDataWithTimepoints` — per-signal incremental data
  /// - `ext.rohd.currentTime` — current simulation time
  void _registerServiceExtensions() {
    if (_extensionsRegistered) {
      return;
    }
    _extensionsRegistered = true;

    // Print the VM service URI so users can connect from DevTools.
    unawaited(
      developer.Service.getInfo().then((info) {
        final uri = info.serverUri;
        if (uri != null) {
          // ignore: avoid_print
          print('ROHD VM Service URI: $uri');
        }
      }),
    );

    // Structure query (no parameters needed)
    developer.registerExtension(
      'ext.rohd.waveformStructure',
      (method, parameters) async =>
          developer.ServiceExtensionResponse.result(structureJSON),
    );

    // Waveform data in a time range
    // Params: signalIdsJson, startTime, endTime
    // Note: result() requires a JSON *object* string, so we wrap the array.
    developer.registerExtension('ext.rohd.waveformData', (
      method,
      parameters,
    ) async {
      final signalIdsJson = parameters['signalIdsJson'] ?? '[]';
      final startTime = int.tryParse(parameters['startTime'] ?? '0') ?? 0;
      final endTime = int.tryParse(parameters['endTime'] ?? '-1') ?? -1;
      final result = getWaveformsJSON(signalIdsJson, startTime, endTime);
      return developer.ServiceExtensionResponse.result('{"data": $result}');
    });

    // Incremental data since a time
    // Params: signalIdsJson, sinceTime
    // Note: result() requires a JSON *object* string, so we wrap the array.
    developer.registerExtension('ext.rohd.waveformDataSince', (
      method,
      parameters,
    ) async {
      final signalIdsJson = parameters['signalIdsJson'] ?? '[]';
      final sinceTime = int.tryParse(parameters['sinceTime'] ?? '0') ?? 0;
      final result = getDataSinceJSON(signalIdsJson, sinceTime);
      return developer.ServiceExtensionResponse.result('{"data": $result}');
    });

    // Per-signal timepoint data
    // Params: signalTimepointsJson
    // Note: result() requires a JSON *object* string, so we wrap the array.
    developer.registerExtension('ext.rohd.waveformDataWithTimepoints', (
      method,
      parameters,
    ) async {
      final timepointsJson = parameters['signalTimepointsJson'] ?? '{}';
      final result = getDataWithTimepointsJSON(timepointsJson);
      return developer.ServiceExtensionResponse.result('{"data": $result}');
    });

    // Current simulation time
    developer.registerExtension(
      'ext.rohd.currentTime',
      (method, parameters) async => developer.ServiceExtensionResponse.result(
        jsonEncode({'currentTime': _currentTime}),
      ),
    );

    // Snapshot: all signal values at a given time Params: time (required)
    // Returns: {"time": int, "signals": {signalId: {"value": str, "name": str,
    // "width": int, "direction": str?}, ...}}
    developer.registerExtension('ext.rohd.snapshot', (
      method,
      parameters,
    ) async {
      final time = int.tryParse(parameters['time'] ?? '') ?? _currentTime;
      final result = getSnapshotJSON(time);
      return developer.ServiceExtensionResponse.result(result);
    });

    // Signal dictionary: maps integer indices to signal IDs/metadata.
    // Called once after getModuleStructure to establish a shared lookup table.
    // This enables compact int-keyed payloads in snapshot and waveform calls.
    developer.registerExtension(
      'ext.rohd.signalDictionary',
      (method, parameters) async =>
          developer.ServiceExtensionResponse.result(getSignalDictionaryJSON()),
    );

    // Compact snapshot: integer-keyed values only (requires dictionary).
    // Params: time (required)
    // Returns: {"time": int, "v": {"0": "val", "1": "val", ...}}
    developer.registerExtension('ext.rohd.snapshotCompact', (
      method,
      parameters,
    ) async {
      final time = int.tryParse(parameters['time'] ?? '') ?? _currentTime;
      return developer.ServiceExtensionResponse.result(
        getSnapshotCompactJSON(time),
      );
    });

    // Compact waveform data: integer-keyed signal data.
    // Params: signalIndicesJson (JSON array of int indices),
    //         startTime, endTime
    // Returns: {"data": [{"i": 0, "d": [{"t": 100, "v": "1"}, ...]}, ...]}
    developer.registerExtension('ext.rohd.waveformDataCompact', (
      method,
      parameters,
    ) async {
      final indicesJson = parameters['signalIndicesJson'] ?? '[]';
      final startTime = int.tryParse(parameters['startTime'] ?? '0') ?? 0;
      final endTime = int.tryParse(parameters['endTime'] ?? '-1') ?? -1;
      final result = getWaveformsCompactJSON(indicesJson, startTime, endTime);
      return developer.ServiceExtensionResponse.result('{"data": $result}');
    });

    // Compact waveform data with per-signal timepoints.
    // Params: signalTimepointsJson (JSON map: int index → last timepoint)
    // Returns: {"data": [{"i": 0, "d": [{"t": 100, "v": "1"}, ...]}, ...]}
    developer.registerExtension('ext.rohd.waveformDataWithTimepointsCompact', (
      method,
      parameters,
    ) async {
      final timepointsJson = parameters['signalTimepointsJson'] ?? '{}';
      final result = getDataWithTimepointsCompactJSON(timepointsJson);
      return developer.ServiceExtensionResponse.result('{"data": $result}');
    });
  }

  /// Collect all signals from the module hierarchy.
  void _collectSignals(Module module, [String parentPath = '']) {
    // Always use instanceName (module.name) for signal path construction.
    // The hierarchy JSON uses instanceName for all modules, so the
    // WaveformDataService paths must match.
    final moduleName = module.name;
    final modulePath =
        parentPath.isEmpty ? moduleName : '$parentPath/$moduleName';

    // Register input signals
    for (final entry in module.inputs.entries) {
      _registerSignal(
        logic: entry.value,
        name: entry.key,
        scopeId: modulePath,
        direction: 'input',
      );
    }

    // Register output signals
    for (final entry in module.outputs.entries) {
      _registerSignal(
        logic: entry.value,
        name: entry.key,
        scopeId: modulePath,
        direction: 'output',
      );
    }

    // Register internal signals.
    final uniquifier = Uniquifier(
      reservedNames: {...module.inputs.keys, ...module.outputs.keys},
    );
    for (final sig in module.signals) {
      if (!module.inputs.containsValue(sig) &&
          !module.outputs.containsValue(sig)) {
        final name = uniquifier.getUniqueName(initialName: sig.name);
        _registerSignal(
          logic: sig,
          name: name,
          scopeId: modulePath,
          direction: 'internal',
        );
      }
    }

    // Recurse into submodules
    for (final subModule in module.subModules) {
      _collectSignals(subModule, modulePath);
    }
  }

  /// Register a signal for tracking.
  void _registerSignal({
    required Logic logic,
    required String name,
    required String scopeId,
    required String direction,
  }) {
    final fullPath = '$scopeId/$name';
    final id = fullPath;

    _signalMetadata[id] = TrackedSignal(
      id: id,
      name: name,
      width: logic.width,
      scopeId: scopeId,
      fullPath: fullPath,
      direction: direction,
    );

    _signalData[id] = [];
    _logicToIdMap[logic] = id;

    // Assign a stable integer index for compact JSON transport.
    final idx = _signalIndex.length;
    _signalIndex[id] = idx;
    _signalIndexReverse[idx] = id;
    // Don't record initial value here - signals may not be driven yet.
    // WaveDumper._writeScope() will record initial values at the right time.
  }

  /// Record a value change for a signal by its ID.
  ///
  /// [signalId] is the hierarchical path (e.g., 'top/counter/count').
  /// [time] is the simulation time.
  /// [value] is the new value as a string.
  ///
  /// In VCD mode (no FST writer attached), the change is stored in the
  /// in-memory [_signalData] map. If there's already an entry at the same
  /// timestamp, it is replaced (like VCD viewers show the latest value).
  ///
  /// In FST mode, the change is **not** stored in [_signalData] because
  /// the [FstWriter] keeps the hot buffer and flushed blocks on disk.
  /// This eliminates unbounded memory growth for long simulations.
  void recordChange(String signalId, int time, String value) {
    _currentTime = time > _currentTime ? time : _currentTime;

    // In FST mode, skip in-memory storage — the FstWriter holds the hot
    // buffer and flushed blocks on disk.  Query methods read from there.
    if (isFstBacked) {
      return;
    }

    _signalData.putIfAbsent(signalId, () => []);
    final changes = _signalData[signalId]!;

    // Replace existing entry at same time, or append new entry
    if (changes.isNotEmpty && changes.last.time == time) {
      changes[changes.length - 1] = ValueChange(time: time, value: value);
    } else {
      changes.add(ValueChange(time: time, value: value));
    }
  }

  /// Record a value change for a Logic object.
  ///
  /// This is the preferred method when called from WaveDumper.
  void recordLogicChange(Logic logic, int time) {
    final signalId = _logicToIdMap[logic];
    if (signalId == null) {
      return;
    }

    final value = _formatLogicValue(logic);
    recordChange(signalId, time, value);

    // Debug logging disabled to reduce noise.
    // The WaveformDataService maintains a separate in-memory copy of waveforms
    // for DevTools queries (parallel to WaveDumper which writes to file).
    // This is necessary because DevTools needs a queryable API.
  }

  /// Format a Logic value as a string suitable for JSON.
  String _formatLogicValue(Logic logic) {
    final value = logic.value;
    if (logic.width == 1) {
      return value.toString(includeWidth: false);
    } else if (!value.isValid) {
      // Handle invalid values (x, z) by showing the full representation
      return value.toString(includeWidth: false);
    } else {
      // Format as hex for valid multi-bit signals
      // Use toBigInt() to handle values larger than 64 bits
      final hexStr = value.toBigInt().toRadixString(16).toUpperCase();
      return '0x$hexStr';
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FST-backed query helpers
  //
  // These methods read historical data from flushed VcData blocks on disk
  // and merge with the FstWriter's unflushed hot buffer.  Used by the JSON
  // APIs when [isFstBacked] is true.
  // ─────────────────────────────────────────────────────────────────────────

  /// Query FST-backed signal data for [signalId] in time range
  /// [startTime] .. [endTime].
  ///
  /// Reads flushed VcData blocks from disk via [_fstBlockReader] and
  /// unflushed changes from [_fstWriter]'s hot buffer, merging them into
  /// a sorted list of [ValueChange]s.
  List<ValueChange> _queryFstSignal(
      String signalId, int startTime, int endTime) {
    final handleIdx = _signalIdToFstHandle[signalId];
    if (handleIdx == null) {
      return [];
    }

    final writer = _fstWriter!;
    final reader = _fstBlockReader!;
    final blocks = writer.blockIndex;
    final result = <ValueChange>[];

    // 1. Read from flushed blocks that overlap [startTime, endTime].
    for (final block in blocks) {
      if (block.endTime < startTime || block.startTime > endTime) {
        continue;
      }

      final changes = reader.readBlock(
        block,
        handleIndices: {handleIdx},
        startTime: startTime,
        endTime: endTime,
      );

      final signalChanges = changes[handleIdx];
      if (signalChanges != null) {
        for (final c in signalChanges) {
          result.add(ValueChange(time: c.time, value: c.value));
        }
      }
    }

    // 2. Read from hot buffer (unflushed changes after last block).
    final hotChanges = writer.queryHotBuffer(handleIdx, startTime, endTime);
    for (final c in hotChanges) {
      result.add(ValueChange(time: c.time, value: c.value));
    }

    // Blocks are chronological and hot buffer is after all blocks, so the
    // result is already sorted.  Sort defensively in case of overlap.
    result.sort((a, b) => a.time.compareTo(b.time));

    return result;
  }

  /// Get the value of an FST-backed signal at-or-before [time].
  ///
  /// Searches the hot buffer first (most recent), then flushed blocks from
  /// newest to oldest.  Falls back to block frame values (carry-over state
  /// at block start) when no explicit change is found.
  String? _getValueAtTimeFst(String signalId, int time) {
    final handleIdx = _signalIdToFstHandle[signalId];
    if (handleIdx == null) {
      return null;
    }

    final writer = _fstWriter!;
    final reader = _fstBlockReader!;
    final blocks = writer.blockIndex;

    // 1. Check hot buffer (unflushed changes after last flushed block).
    final hotChanges = writer.queryHotBuffer(handleIdx, 0, time);
    if (hotChanges.isNotEmpty) {
      return hotChanges.last.value;
    }

    // 2. Search flushed blocks from newest to oldest.
    for (var i = blocks.length - 1; i >= 0; i--) {
      final block = blocks[i];
      if (block.startTime > time) {
        continue;
      }

      // Read all changes for this signal up to `time`.
      final changes = reader.readBlock(
        block,
        handleIndices: {handleIdx},
        endTime: time,
      );

      final signalChanges = changes[handleIdx];
      if (signalChanges != null && signalChanges.isNotEmpty) {
        return signalChanges.last.value;
      }

      // No explicit changes — use the frame carry-over value.
      final frame = reader.readBlockFrame(block);
      return frame[handleIdx];
    }

    // 3. No data found — signal is in its initial/undriven state.
    return null;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // JSON API for DevTools (called via VM Service evaluate())
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns the module structure as JSON (signal metadata, no waveform data).
  ///
  /// This is used by DevTools to discover available signals.
  String get structureJSON {
    if (_rootModule == null && _signalMetadata.isEmpty) {
      return jsonEncode({
        'status': 'fail',
        'reason': 'WaveformDataService not initialized',
      });
    }

    final modules = <Map<String, dynamic>>[];

    // Group signals by scope
    final signalsByScope = <String, List<TrackedSignal>>{};
    for (final signal in _signalMetadata.values) {
      signalsByScope.putIfAbsent(signal.scopeId, () => []);
      signalsByScope[signal.scopeId]!.add(signal);
    }

    // Build module structure from scopes
    for (final entry in signalsByScope.entries) {
      modules.add({
        'id': entry.key,
        'name': entry.key.split('/').last,
        'kind': 'HierarchyKind.module',
        'type': entry.key.split('/').last,
        'signals': entry.value.map((s) => s.toJson()).toList(),
        'children': <Map<String, dynamic>>[],
      });
    }

    return jsonEncode({
      'metadata': {
        'source': 'WaveformDataService',
        'timescale': '1ps',
        'date': DateTime.now().toIso8601String(),
        'startTime': 0,
        'endTime': _currentTime,
      },
      'modules': modules,
    });
  }

  /// Returns waveform data for specified signals in a time range.
  ///
  /// [signalIdsJson] is a JSON-encoded list of signal IDs.
  /// [startTime] is the start of the time range (inclusive).
  /// [endTime] is the end of the time range (-1 means current time).
  String getWaveformsJSON(String signalIdsJson, int startTime, int endTime) {
    final signalIds =
        (jsonDecode(signalIdsJson) as List<dynamic>).cast<String>();
    final end = endTime < 0 ? _currentTime : endTime;

    developer.log(
      'getWaveformsJSON: requested=${signalIds.length} ids=$signalIds '
      'timeRange=[$startTime..$end] '
      'knownSignals=${_signalData.length}',
      name: 'WaveformDataService',
    );

    final result = <Map<String, dynamic>>[];

    for (final signalId in signalIds) {
      List<Map<String, dynamic>> filteredData;

      if (isFstBacked) {
        // FST mode: read from disk blocks + hot buffer.
        filteredData = _queryFstSignal(signalId, startTime, end)
            .map((c) => c.toJson())
            .toList();
      } else {
        // VCD mode: read from in-memory cache.
        final changes = _signalData[signalId] ?? [];
        filteredData = changes
            .where((c) => c.time >= startTime && c.time <= end)
            .map((c) => c.toJson())
            .toList();
      }

      final found = isFstBacked
          ? _signalIdToFstHandle.containsKey(signalId)
          : _signalData.containsKey(signalId);

      developer.log(
        '  signalId="$signalId" found=$found '
        'filtered=${filteredData.length} fstBacked=$isFstBacked',
        name: 'WaveformDataService',
      );

      if (!found) {
        final known = isFstBacked
            ? _signalIdToFstHandle.keys.take(5).toList()
            : _signalData.keys.take(5).toList();
        developer.log(
          '    NOT FOUND — known IDs (first 5): $known',
          name: 'WaveformDataService',
        );
      }

      result.add({'signalId': signalId, 'data': filteredData});
    }

    return jsonEncode(result);
  }

  /// Returns incremental waveform data since a given time.
  ///
  /// [signalIdsJson] is a JSON-encoded list of signal IDs.
  /// [sinceTime] is the time after which to return data.
  String getDataSinceJSON(String signalIdsJson, int sinceTime) {
    final signalIds =
        (jsonDecode(signalIdsJson) as List<dynamic>).cast<String>();

    final result = <Map<String, dynamic>>[];

    for (final signalId in signalIds) {
      List<Map<String, dynamic>> filteredData;

      if (isFstBacked) {
        filteredData = _queryFstSignal(signalId, sinceTime, _currentTime)
            .map((c) => c.toJson())
            .toList();
      } else {
        final changes = _signalData[signalId] ?? [];
        filteredData = changes
            .where((c) => c.time >= sinceTime)
            .map((c) => c.toJson())
            .toList();
      }

      result.add({'signalId': signalId, 'data': filteredData});
    }

    return jsonEncode(result);
  }

  /// Returns incremental waveform data using per-signal timepoints.
  ///
  /// This enables selective waveform transmission where each signal can have a
  /// different last-fetched timepoint. This is used for lazy-loading and
  /// handling dynamic signal addition/removal in the DevTools UI.
  ///
  /// [signalTimepointsJson] is a JSON-encoded map of signal ID -> last
  /// timepoint. Only data points after each signal's timepoint are returned.
  String getDataWithTimepointsJSON(String signalTimepointsJson) {
    final timepointsMap =
        jsonDecode(signalTimepointsJson) as Map<String, dynamic>;

    // Convert string keys and values to proper types
    final signalTimepoints = <String, int>{};
    for (final entry in timepointsMap.entries) {
      final timepoint = entry.value;
      signalTimepoints[entry.key] =
          (timepoint is int) ? timepoint : int.parse(timepoint.toString());
    }

    final result = <Map<String, dynamic>>[];

    for (final entry in signalTimepoints.entries) {
      final signalId = entry.key;
      final sinceTime = entry.value;

      List<Map<String, dynamic>> filteredData;

      if (isFstBacked) {
        // sinceTime is exclusive (> not >=), so use sinceTime + 1 as start.
        filteredData = _queryFstSignal(signalId, sinceTime + 1, _currentTime)
            .map((c) => c.toJson())
            .toList();
      } else {
        final changes = _signalData[signalId] ?? [];
        filteredData = changes
            .where((c) => c.time > sinceTime)
            .map((c) => c.toJson())
            .toList();
      }

      result.add({'signalId': signalId, 'data': filteredData});
    }

    return jsonEncode(result);
  }

  /// Returns a snapshot of all signal values at the given [time].
  ///
  /// For each tracked signal, finds the value at-or-before [time] using
  /// binary search. Returns a JSON object:
  /// ```json
  /// {
  ///   "time": 500,
  ///   "signals": {
  ///     "top/counter/clk": {"value": "1", "name": "clk", "width": 1, "direction": "input"},
  ///     ...
  ///   }
  /// }
  /// ```
  String getSnapshotJSON(int time) {
    final signals = <String, Map<String, dynamic>>{};

    if (isFstBacked) {
      // FST mode: iterate over all tracked signals and query disk + hot
      // buffer for the value at-or-before `time`.
      for (final signalId in _signalIdToFstHandle.keys) {
        final metadata = _signalMetadata[signalId];
        final value = _getValueAtTimeFst(signalId, time);

        signals[signalId] = {
          'value': value ?? 'x',
          'name': metadata?.name ?? signalId.split('/').last,
          'width': metadata?.width ?? 1,
          if (metadata?.direction != null) 'direction': metadata!.direction,
        };
      }
    } else {
      // VCD mode: in-memory binary search.
      for (final entry in _signalData.entries) {
        final signalId = entry.key;
        final changes = entry.value;
        final metadata = _signalMetadata[signalId];

        // Binary search for value at-or-before time
        String? value;
        if (changes.isNotEmpty) {
          var lo = 0;
          var hi = changes.length - 1;
          var res = -1;
          while (lo <= hi) {
            final mid = (lo + hi) >> 1;
            if (changes[mid].time <= time) {
              res = mid;
              lo = mid + 1;
            } else {
              hi = mid - 1;
            }
          }
          if (res != -1) {
            value = changes[res].value;
          }
        }

        signals[signalId] = {
          'value': value ?? 'x',
          'name': metadata?.name ?? signalId.split('/').last,
          'width': metadata?.width ?? 1,
          if (metadata?.direction != null) 'direction': metadata!.direction,
        };
      }
    }

    return jsonEncode({'time': time, 'signals': signals});
  }

  /// Returns a list of all tracked signal IDs.
  String get signalIdsJSON => jsonEncode(_signalMetadata.keys.toList());

  /// Returns metadata for all tracked signals.
  String get signalMetadataJSON =>
      jsonEncode(_signalMetadata.values.map((s) => s.toJson()).toList());

  // ─────────────────────────────────────────────────────────────────────────
  // Compact (integer-keyed) JSON APIs
  //
  // These use integer indices instead of full signal-path strings as JSON
  // keys, reducing payload size by ~88% and string object allocations by
  // ~80%.  The consumer must first call getSignalDictionaryJSON() to
  // establish the shared mapping.
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns the signal dictionary: an ordered list of
  /// `{index, id, name, width, direction}` entries.
  ///
  /// The consumer caches this once and uses the integer `index` to decode
  /// all subsequent compact payloads.
  ///
  /// ```json
  /// {
  ///   "signals": [
  ///     {"i": 0, "id": "top/clk", "name": "clk", "width": 1,
  ///      "direction": "input"},
  ///     {"i": 1, "id": "top/counter/q", "name": "q", "width": 8,
  ///      "direction": "output"},
  ///     ...
  ///   ]
  /// }
  /// ```
  String getSignalDictionaryJSON() {
    final signals = <Map<String, dynamic>>[];
    for (final entry in _signalIndex.entries) {
      final signalId = entry.key;
      final idx = entry.value;
      final meta = _signalMetadata[signalId];
      signals.add({
        'i': idx,
        'id': signalId,
        'name': meta?.name ?? signalId.split('/').last,
        'width': meta?.width ?? 1,
        'direction': meta?.direction ?? 'internal',
      });
    }
    return jsonEncode({'signals': signals});
  }

  /// Compact snapshot: integer-keyed values only.
  ///
  /// ```json
  /// {"time": 500, "v": {"0": "1", "1": "0xFF", ...}}
  /// ```
  ///
  /// The consumer resolves each integer key back to a signal ID using the
  /// cached dictionary from [getSignalDictionaryJSON].
  String getSnapshotCompactJSON(int time) {
    final values = <String, String>{};

    if (isFstBacked) {
      // FST mode: query disk + hot buffer for each signal.
      for (final entry in _signalIdToFstHandle.entries) {
        final signalId = entry.key;
        final idx = _signalIndex[signalId];
        if (idx == null) {
          continue;
        }

        final value = _getValueAtTimeFst(signalId, time) ?? 'x';
        values[idx.toString()] = value;
      }
    } else {
      // VCD mode: in-memory binary search.
      for (final entry in _signalData.entries) {
        final signalId = entry.key;
        final changes = entry.value;
        final idx = _signalIndex[signalId];
        if (idx == null) {
          continue;
        }

        var value = 'x';
        if (changes.isNotEmpty) {
          var lo = 0;
          var hi = changes.length - 1;
          var res = -1;
          while (lo <= hi) {
            final mid = (lo + hi) >> 1;
            if (changes[mid].time <= time) {
              res = mid;
              lo = mid + 1;
            } else {
              hi = mid - 1;
            }
          }
          if (res != -1) {
            value = changes[res].value;
          }
        }

        values[idx.toString()] = value;
      }
    }

    return jsonEncode({'time': time, 'v': values});
  }

  /// Compact waveform data: integer-keyed signal data.
  ///
  /// ```json
  /// [{"i": 0, "d": [{"t": 100, "v": "1"}, ...]}, ...]
  /// ```
  ///
  /// Uses short keys (`i` for index, `d` for data array, `t` for time,
  /// `v` for value) to minimise payload size.
  String getWaveformsCompactJSON(
    String signalIndicesJson,
    int startTime,
    int endTime,
  ) {
    final indices =
        (jsonDecode(signalIndicesJson) as List<dynamic>).cast<int>();
    final end = endTime < 0 ? _currentTime : endTime;

    final result = <Map<String, dynamic>>[];

    for (final idx in indices) {
      final signalId = _signalIndexReverse[idx];
      if (signalId == null) {
        continue;
      }

      List<Map<String, dynamic>> filteredData;

      if (isFstBacked) {
        filteredData = _queryFstSignal(signalId, startTime, end)
            .map((c) => <String, dynamic>{'t': c.time, 'v': c.value})
            .toList();
      } else {
        final changes = _signalData[signalId] ?? [];
        filteredData = changes
            .where((c) => c.time >= startTime && c.time <= end)
            .map((c) => <String, dynamic>{'t': c.time, 'v': c.value})
            .toList();
      }

      result.add({'i': idx, 'd': filteredData});
    }

    return jsonEncode(result);
  }

  /// Compact waveform data with per-signal timepoints (integer-keyed).
  ///
  /// [signalTimepointsJson] is a JSON-encoded map of integer index →
  /// last timepoint.
  ///
  /// ```json
  /// [{"i": 0, "d": [{"t": 200, "v": "0"}, ...]}, ...]
  /// ```
  String getDataWithTimepointsCompactJSON(String signalTimepointsJson) {
    final timepointsMap =
        jsonDecode(signalTimepointsJson) as Map<String, dynamic>;

    final result = <Map<String, dynamic>>[];

    for (final entry in timepointsMap.entries) {
      final idx = int.tryParse(entry.key);
      if (idx == null) {
        continue;
      }
      final sinceTime = (entry.value is int)
          ? entry.value as int
          : int.parse(entry.value.toString());

      final signalId = _signalIndexReverse[idx];
      if (signalId == null) {
        continue;
      }

      List<Map<String, dynamic>> filteredData;

      if (isFstBacked) {
        filteredData = _queryFstSignal(signalId, sinceTime + 1, _currentTime)
            .map((c) => <String, dynamic>{'t': c.time, 'v': c.value})
            .toList();
      } else {
        final changes = _signalData[signalId] ?? [];
        filteredData = changes
            .where((c) => c.time > sinceTime)
            .map((c) => <String, dynamic>{'t': c.time, 'v': c.value})
            .toList();
      }

      result.add({'i': idx, 'd': filteredData});
    }

    return jsonEncode(result);
  }
}
