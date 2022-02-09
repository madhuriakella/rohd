/// Copyright (C) 2021 Intel Corporation
/// SPDX-License-Identifier: BSD-3-Clause
///
/// wave_dumper.dart
/// Waveform dumper for a given module hierarchy, dumps to .vcd file
///
/// 2021 May 7
/// Author: Max Korbel <max.korbel@intel.com>
///

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:rohd/src/utilities/sanitizer.dart';
import 'package:rohd/src/utilities/uniquifier.dart';

/// A waveform dumper for simulations.
///
/// Outputs to vcd format at [outputPath].  [module] must be built prior to attaching the [WaveDumper].
class WaveDumper {
  /// The [Module] being dumped.
  final Module module;

  /// The output filepath of the generated waveforms.
  final String outputPath;

  /// The file to write dumped output waveform to.
  final File _outputFile;

  /// A counter for tracking signal names in the VCD file.
  int _signalMarkerIdx = 0;

  /// Stores the mapping from [Logic] to signal marker in the VCD file.
  final Map<Logic, String> _signalToMarkerMap = {};

  /// A set of all [Logic]s that have changed in this timestamp so far.
  ///
  /// This spans across multiple inject or changed events if they are in the same
  /// timestamp of the [Simulator].
  final Set<Logic> _changedLogicsThisTimestamp = <Logic>{};

  /// The timestamp which is currently being collected for a dump.
  ///
  /// When the [Simulator] time progresses beyond this, it will dump all the
  /// signals that have changed up until that point at this saved time value.
  var _currentDumpingTimestamp = Simulator.time;

  WaveDumper(this.module, {this.outputPath = 'waves.vcd'})
      : _outputFile = File(outputPath) {
    if (!module.hasBuilt) {
      throw Exception(
          'Module must be built before passed to dumper.  Call build() first.');
    }

    _collectAllSignals();

    _writeHeader();
    _writeScope();

    Simulator.preTick.listen((args) {
      if (Simulator.time != _currentDumpingTimestamp) {
        if (_changedLogicsThisTimestamp.isNotEmpty) {
          // no need to write blank timestamps
          _captureTimestamp(_currentDumpingTimestamp);
        }
        _currentDumpingTimestamp = Simulator.time;
      }
    });

    Simulator.simulationEnded.then((args) {
      _captureTimestamp(Simulator.time);
    });
  }

  /// Registers all signal value changes to write updates to the dumped VCD.
  void _collectAllSignals() {
    var modulesToParse = <Module>[module];
    for (var i = 0; i < modulesToParse.length; i++) {
      var m = modulesToParse[i];
      for (var sig in m.signals) {
        if (sig is Const) {
          // constant values are "boring" to inspect
          continue;
        }

        _signalToMarkerMap[sig] = 's${_signalMarkerIdx++}';
        sig.changed.listen((args) {
          _changedLogicsThisTimestamp.add(sig);
        });
      }
      for (var subm in m.subModules) {
        if (subm is InlineSystemVerilog) {
          // the InlineSystemVerilog modules are "boring" to inspect
          continue;
        }
        modulesToParse.add(subm);
      }
    }
  }

  /// Writes the top header for the VCD file.
  void _writeHeader() {
    var dateString = DateTime.now().toIso8601String();
    var timescale = '1ps';
    var header = '''
\$date
  $dateString
\$end
\$version
  ROHD v0.0.1
\$end
\$comment
  Generated by ROHD - www.github.com/intel/rohd
\$end
\$timescale $timescale \$end
''';
    _outputFile.writeAsStringSync(header);
  }

  /// Writes the scope of the VCD, including signal and hierarchy declarations, as well as initial values.
  void _writeScope() {
    var scopeString = _computeScopeString(module);
    scopeString += '\$enddefinitions \$end\n';
    scopeString += '\$dumpvars\n';
    _outputFile.writeAsStringSync(scopeString, mode: FileMode.append);
    for (var element in _signalToMarkerMap.keys) {
      _writeSignalValueUpdate(element);
    }
    _outputFile.writeAsStringSync('\$end\n', mode: FileMode.append);
  }

  /// Generates the top of the scope string (signal and hierarchy definitions).
  String _computeScopeString(Module m, {int indent = 0}) {
    var moduleSignalUniquifier = Uniquifier();
    var padding = List.filled(indent, '  ').join();
    var scopeString = '$padding\$scope module ${m.uniqueInstanceName} \$end\n';
    var innerScopeString = '';
    for (var sig in m.signals) {
      if (!_signalToMarkerMap.containsKey(sig)) continue;

      var width = sig.width;
      var marker = _signalToMarkerMap[sig];
      var signalName = Sanitizer.sanitizeSV(sig.name);
      signalName = moduleSignalUniquifier.getUniqueName(
          initialName: signalName, reserved: sig.isPort);
      innerScopeString +=
          '  $padding\$var wire $width $marker $signalName \$end\n';
    }
    for (var subModule in m.subModules) {
      innerScopeString += _computeScopeString(subModule, indent: indent + 1);
    }
    if (innerScopeString.isEmpty) {
      // no need to dump empty scopes
      return '';
    }
    scopeString += innerScopeString;
    scopeString += '$padding\$upscope \$end\n';
    return scopeString;
  }

  /// Writes the current timestamp to the VCD.
  void _captureTimestamp(int timestamp) {
    var timestampString = '#$timestamp\n';
    _outputFile.writeAsStringSync(timestampString, mode: FileMode.append);

    for (var signal in _changedLogicsThisTimestamp) {
      _writeSignalValueUpdate(signal);
    }
    _changedLogicsThisTimestamp.clear();
  }

  /// Writes the current value of [signal] to the VCD.
  void _writeSignalValueUpdate(Logic signal) {
    var updateValue = signal.width > 1
        ? 'b' +
            signal.value.reversed.toList().map((e) => e.toString()).join() +
            ' '
        : signal.bit.toString();
    var marker = _signalToMarkerMap[signal];
    var updateString = '$updateValue$marker\n';
    _outputFile.writeAsStringSync(updateString, mode: FileMode.append);
  }
}

@Deprecated('Use WaveDumper instead')
typedef Dumper = WaveDumper;