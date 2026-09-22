/// This is copied from Cargokit (which is the official way to use it currently)
/// Details: https://fzyzcjy.github.io/flutter_rust_bridge/manual/integrate/builtin

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as path;

import 'util.dart';

class _Toolchain {
  _Toolchain(
    this.name,
    this.targets,
  );

  final String name;
  final List<String> targets;
}

class Rustup {
  List<String>? installedTargets(String toolchain) {
    final targets = _installedTargets(toolchain);
    return targets != null ? List.unmodifiable(targets) : null;
  }

  void installToolchain(String toolchain) {
    log.info("Installing Rust toolchain: $toolchain");
    runCommand("rustup", ['toolchain', 'install', toolchain]);
    _installedToolchains
        .add(_Toolchain(toolchain, _getInstalledTargets(toolchain)));
  }

  void installTarget(
    String target, {
    required String toolchain,
  }) {
    log.info("Installing Rust target: $target");
    runCommand("rustup", [
      'target',
      'add',
      '--toolchain',
      toolchain,
      target,
    ]);
    _installedTargets(toolchain)?.add(target);
  }

  final List<_Toolchain> _installedToolchains;

  Rustup() : _installedToolchains = _getInstalledToolchains();

  List<String>? _installedTargets(String toolchain) => _installedToolchains
      .firstWhereOrNull(
          (e) => e.name == toolchain || e.name.startsWith('$toolchain-'))
      ?.targets;

  static List<_Toolchain> _getInstalledToolchains() {
    String extractToolchainName(String line) {
      // ignore (default) after toolchain name
      final parts = line.split(' ');
      return parts[0];
    }

    final res = runCommand("rustup", ['toolchain', 'list']);

    // Vizor's opt-in release override can select an exact Rust toolchain.
    Pattern supported =
        RegExp(r"^(stable|beta|nightly|[0-9]+\.[0-9]+\.[0-9]+)(-|$)");
    final lines = res.stdout
        .toString()
        .split('\n')
        .where((e) => e.isNotEmpty && e.startsWith(supported))
        .map(extractToolchainName)
        .toList(growable: true);

    // A toolchain that matches the pattern is not necessarily one rustup will
    // accept as a `--toolchain` argument. Custom toolchains linked into rustup
    // by other SDKs (a Solana `1.89.0-sbpf-solana-v1.52`, for one) start with a
    // version number and so pass the filter above, but `rustup target list
    // --toolchain <that>` fails with "invalid toolchain name" — and because
    // this enumeration runs for *every* installed toolchain, one unrelated
    // entry in the user's rustup took the whole build down, long before
    // anything here had chosen a toolchain to build with. Skip what cannot be
    // described instead of failing; the toolchain actually selected is
    // validated by `installedTargets` on its own.
    final toolchains = <_Toolchain>[];
    for (final name in lines) {
      try {
        toolchains.add(_Toolchain(name, _getInstalledTargets(name)));
      } catch (error) {
        log.fine('Ignoring rustup toolchain $name: $error');
      }
    }
    return toolchains;
  }

  static List<String> _getInstalledTargets(String toolchain) {
    final res = runCommand("rustup", [
      'target',
      'list',
      '--toolchain',
      toolchain,
      '--installed',
    ]);
    final lines = res.stdout
        .toString()
        .split('\n')
        .where((e) => e.isNotEmpty)
        .toList(growable: true);
    return lines;
  }

  bool _didInstallRustSrcForNightly = false;

  void installRustSrcForNightly() {
    if (_didInstallRustSrcForNightly) {
      return;
    }
    // Useful for -Z build-std
    runCommand(
      "rustup",
      ['component', 'add', 'rust-src', '--toolchain', 'nightly'],
    );
    _didInstallRustSrcForNightly = true;
  }

  static String? executablePath() {
    final envPath = Platform.environment['PATH'];
    final envPathSeparator = Platform.isWindows ? ';' : ':';
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    final paths = [
      if (home != null) path.join(home, '.cargo', 'bin'),
      if (envPath != null) ...envPath.split(envPathSeparator),
    ];
    for (final p in paths) {
      final rustup = Platform.isWindows ? 'rustup.exe' : 'rustup';
      final rustupPath = path.join(p, rustup);
      if (File(rustupPath).existsSync()) {
        return rustupPath;
      }
    }
    return null;
  }
}
