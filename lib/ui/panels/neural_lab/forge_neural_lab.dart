import 'package:flutter/material.dart';

import '../../engine/network_view.dart';
import 'neural_lab_panel.dart';

/// Neural Lab: two clearly separated modes.
///
/// * **Forge network** (default): the real engine as a graph. Agents, tools,
///   models, keys and providers, with edges that light up only when the
///   engine's event bus reports traffic across them.
/// * **Local MLP experiment**: the original 3D training visualisation. It runs
///   on generated data on this device and is labelled as not being Forge data.
class NeuralLabPanel extends StatefulWidget {
  const NeuralLabPanel({super.key});

  @override
  State<NeuralLabPanel> createState() => _NeuralLabPanelState();
}

enum _Mode { network, experiment }

class _NeuralLabPanelState extends State<NeuralLabPanel> {
  _Mode _mode = _Mode.network;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<_Mode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _Mode.network, label: Text('Forge network (live)'), icon: Icon(Icons.hub_outlined)),
              ButtonSegment(value: _Mode.experiment, label: Text('Local MLP experiment'), icon: Icon(Icons.science_outlined)),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
        ),
      ),
      Expanded(child: _mode == _Mode.network ? const EngineNetworkView() : const MlpExperimentPanel()),
    ]);
  }
}
