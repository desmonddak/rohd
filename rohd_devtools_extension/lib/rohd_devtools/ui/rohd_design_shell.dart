// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// rohd_design_shell.dart
// Terminal-style DevTools client for target-owned ROHD commands.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rohd_devtools_extension/rohd_devtools/cli/rohd_design_dtd_service.dart';

/// Obtains the current paused-target command proxy.
typedef RohdDesignCommandTargetProvider = Future<RohdDesignCommandTarget?>
    Function();

/// A persistent terminal-style client for target-owned ROHD commands.
class RohdDesignShell extends StatefulWidget {
  /// Creates a shell that resolves a command target as commands are submitted.
  const RohdDesignShell({
    required this.targetProvider,
    super.key,
  });

  /// Provides the current debug target without duplicating command semantics.
  final RohdDesignCommandTargetProvider targetProvider;

  @override
  State<RohdDesignShell> createState() => _RohdDesignShellState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(
      DiagnosticsProperty<RohdDesignCommandTargetProvider>(
        'targetProvider',
        targetProvider,
      ),
    );
  }
}

class _RohdDesignShellState extends State<RohdDesignShell> {
  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();
  final _outputController = ScrollController();
  final _entries = <_ShellEntry>[];
  final _history = <String>[];
  final _sessionId = 'devtools-${DateTime.now().microsecondsSinceEpoch}';
  var _historyIndex = 0;
  var _running = false;

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocus.dispose();
    _outputController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final input = _inputController.text.trim();
    if (input.isEmpty || _running) {
      return;
    }
    setState(() {
      _entries.add(_ShellEntry(input, isInput: true));
      _history.add(input);
      _historyIndex = _history.length;
      _inputController.clear();
      _running = true;
    });
    _scrollToEnd();

    try {
      final target = await widget.targetProvider();
      if (target == null) {
        throw StateError('No ROHD debug target is connected.');
      }
      final response = await target.command(_sessionId, input);
      if (!mounted) {
        return;
      }
      setState(() => _entries.add(_ShellEntry(_format(response))));
    } on Object catch (error) {
      if (mounted) {
        setState(() => _entries.add(_ShellEntry('$error', isError: true)));
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
        _inputFocus.requestFocus();
        _scrollToEnd();
      }
    }
  }

  Future<void> _complete() async {
    if (_running) {
      return;
    }
    final selection = _inputController.selection;
    final cursor =
        selection.isValid ? selection.baseOffset : _inputController.text.length;
    final target = await widget.targetProvider();
    if (target == null || !mounted) {
      return;
    }
    try {
      final response = await target.complete(
        _sessionId,
        _inputController.text,
        cursor,
      );
      final items = response['items'];
      if (response['ok'] != true || items is! List) {
        return;
      }
      final candidates = items.whereType<String>().toList();
      if (candidates.isEmpty) {
        return;
      }
      final start = _tokenStart(_inputController.text, cursor);
      final replacement = _sharedPrefix(candidates);
      final prefix = _inputController.text.substring(start, cursor);
      if (replacement.length > prefix.length) {
        final value = _inputController.text;
        _inputController.value = TextEditingValue(
          text:
              value.substring(0, start) + replacement + value.substring(cursor),
          selection:
              TextSelection.collapsed(offset: start + replacement.length),
        );
      } else if (candidates.length > 1 && mounted) {
        setState(() => _entries.add(_ShellEntry(candidates.join('  '))));
        _scrollToEnd();
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _entries.add(_ShellEntry('$error', isError: true)));
      }
    }
  }

  void _moveHistory(int delta) {
    if (_history.isEmpty) {
      return;
    }
    final index = (_historyIndex + delta).clamp(0, _history.length);
    setState(() {
      _historyIndex = index;
      _inputController.text = index == _history.length ? '' : _history[index];
      _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length,
      );
    });
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      unawaited(_complete());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveHistory(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveHistory(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_outputController.hasClients) {
        _outputController.jumpTo(_outputController.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: Column(
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            color: colors.surfaceContainerHighest,
            child: Text(
              'ROHD Debug Shell',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _outputController,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _entries.length,
              itemBuilder: (context, index) {
                final entry = _entries[index];
                return SelectableText(
                  entry.isInput ? 'rohd> ${entry.value}' : entry.value,
                  style: TextStyle(
                    color: entry.isError ? colors.error : null,
                    fontFamily: 'monospace',
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Focus(
            onKeyEvent: _handleKey,
            child: TextField(
              controller: _inputController,
              focusNode: _inputFocus,
              enabled: !_running,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                prefixText: 'rohd> ',
                suffixIcon: IconButton(
                  icon: _running
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_upward),
                  onPressed: _running ? null : _submit,
                  tooltip: 'Run command',
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  static int _tokenStart(String input, int cursor) {
    var start = cursor.clamp(0, input.length);
    while (start > 0 && !RegExp(r'\s').hasMatch(input[start - 1])) {
      start--;
    }
    return start;
  }

  static String _sharedPrefix(Iterable<String> candidates) {
    final values = candidates.toList(growable: false);
    if (values.isEmpty) {
      return '';
    }
    var prefix = values.first;
    for (final value in values.skip(1)) {
      var length = 0;
      while (length < prefix.length &&
          length < value.length &&
          prefix.codeUnitAt(length) == value.codeUnitAt(length)) {
        length++;
      }
      prefix = prefix.substring(0, length);
    }
    return prefix;
  }

  static String _format(Map<String, Object?> response) => jsonEncode(response);
}

class _ShellEntry {
  const _ShellEntry(this.value, {this.isInput = false, this.isError = false});

  final String value;
  final bool isInput;
  final bool isError;
}
