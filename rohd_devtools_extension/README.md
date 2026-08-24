# ROHD DevTools Extension

The ROHD DevTools extension provides debugging support for ROHD hardware
designers. It connects to a running Dart VM, reads the ROHD module hierarchy,
and displays live signal information while the debugged program is paused.

Initial proposals and discussions for the devtool can be found at
<https://github.com/intel/rohd/discussions/418>.

## Opening from Flutter DevTools

The normal user flow is through Flutter DevTools:

1. Start debugging a ROHD program.
2. Stop at a breakpoint or otherwise pause the debugged program.
3. Use **Open DevTools in Browser** from VS Code.
4. In the browser DevTools page, open the **ROHD** tab.

See the Flutter DevTools documentation for the surrounding DevTools workflow:
<https://docs.flutter.dev/tools/devtools>.

When opened this way, the extension runs inside Flutter DevTools and uses VS
Code's Dart Tooling Daemon (DTD) integration to attach to and control the
debugged Dart VM.

## Standalone Release Mode

The extension can also run as a standalone app. This is useful when you want to
connect directly to a Dart VM service URI, discover running VMs through a DTD
URI from the app's connection form, and select the specific debug VM to which to
attach.

Run the release web standalone form:

```sh
cd rohd_devtools_extension
flutter run --release -d web-server --web-port=9099 --web-hostname=0.0.0.0 lib/main_standalone.dart
```

Run the release Linux standalone form:

```sh
cd rohd_devtools_extension
flutter run --release -d linux lib/main_standalone.dart
```

If the Linux build needs software rendering, use:

```sh
cd rohd_devtools_extension
flutter run --release -d linux --enable-software-rendering lib/main_standalone.dart
```

The repository's `.vscode/tasks.json` contains development utilities for these
flows, including debug-mode variants. Those VS Code tasks are for extension
development only and may change or be removed; the commands above are the
release-mode forms to use directly.

## Current Features

The in-app help menu is the source of truth for the current feature set. The
main capability today is module-level inspection:

- Select a block from the Module Tree.
- View that module's live port and internal `Logic` values in the Details pane.
- Search and filter the Module Tree and signal list.
- Refresh the module hierarchy from the connected VM.
- Export the signal details table as a PNG.

## Contributions

We welcome contributions to the development of the ROHD DevTools extension.
Please refer to the contributing documentation for guidance on how to get
started.

## Running Tests

The ROHD DevTools extension runs in an iframe when embedded in DevTools, so use
the Chrome platform for browser-based widget tests.

```sh
flutter test --platform chrome test/
```

## Debug Shells

The DTD-attached terminal shell and the DevTools **ROHD Debug Shell** use the
same target-owned command session. Both preserve aliases and command history
for the lifetime of the shell. Use Tab to complete commands, aliases, and
`transparent`; Tab on an exact `find-cell` or `find-signal` path completes from
the live hierarchy. Press Tab again to list ambiguous candidates. Up/Down or
Ctrl-P/Ctrl-N navigate history. Ctrl-A/Ctrl-E move to the start/end of the
line; Ctrl-U/Ctrl-K/Ctrl-W delete text; Ctrl-L clears the terminal; Ctrl-C
cancels a running command; Ctrl-D deletes forward or exits on an empty line.

The DevTools panel provides command output scrollback, input history, and
target-backed Tab completion below the hierarchy view.

```sh
dart run bin/rohd_shell.dart --dtd "$DTD_URI"
```

Use `find-cells <regex> [root-alias] [transparent]` or
`find-signals <regex> [root-alias] [transparent]` to restrict a hierarchy
search to leaf cells or leaf-owned signals. These commands use the same
hierarchy regex/glob engine as DevTools widgets: `*` and `?` are glob
wildcards, `**` crosses hierarchy levels, and regex operators work within each
path segment. Unqualified patterns search at any hierarchy depth.
