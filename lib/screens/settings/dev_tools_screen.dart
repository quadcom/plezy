import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../dev/dev_actions.dart';
import '../../dev/dev_channel.dart';
import '../../dev/server_write_guard.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/dev_log_file.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/settings_section.dart';
import 'logs_screen.dart';

/// Developer tools (local/plans/dev-tools.md): shown only in developer mode,
/// from Settings > Advanced. Every button runs the same action an agent can
/// run through the dev channel (`actions.run`). English only on purpose:
/// it is for the people working on Plezy.
class DevToolsScreen extends StatefulWidget {
  const DevToolsScreen({super.key});

  @override
  State<DevToolsScreen> createState() => _DevToolsScreenState();
}

class _DevToolsScreenState extends State<DevToolsScreen> {
  static const _groupTitles = {
    'look': 'Look (changes nothing)',
    'navigate': 'Move around the app',
    'player': 'Player',
    'app': 'App',
  };

  static const _groupIcons = {
    'look': Symbols.visibility_rounded,
    'navigate': Symbols.explore_rounded,
    'player': Symbols.play_circle_rounded,
    'app': Symbols.build_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DevLogFile.enabledListenable,
      builder: (context, on, _) => FocusedScrollScaffold(
        title: const Text('Developer tools'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList(delegate: SliverChildListDelegate(on ? _sections(context) : [_offNote(context)])),
          ),
        ],
      ),
    );
  }

  Widget _offNote(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      'Developer mode is off. Turn on "Save Log to File" in Settings > Advanced to use these tools.',
      style: TextStyle(color: tokens(context).textMuted),
    ),
  );

  List<Widget> _sections(BuildContext context) {
    final changes = DevChannel.changes;
    return [
      SettingsGroup(
        title: 'Status',
        margin: EdgeInsets.zero,
        children: [
          _info(
            Symbols.developer_mode_rounded,
            'Developer mode',
            DevLogFile.switchFileOn ? 'On (switch file plezy-debug-on)' : 'On (Save Log to File)',
          ),
          _info(
            Symbols.lan_rounded,
            'Agent connection',
            DevChannel.port == 0 ? 'Opening...' : '127.0.0.1:${DevChannel.port} (this device only)',
          ),
          _info(
            Symbols.cloud_off_rounded,
            'Server writes',
            ServerWriteGuard.active
                ? 'Held back (switch file is on). So far: ${ServerWriteGuard.blockedCount}'
                : 'Sent as normal. Only the switch file plezy-debug-on holds them back.',
            onTap: () => _showResult(context, 'Held-back server writes', ServerWriteGuard.recentBlocked()),
          ),
          FocusableListTile(
            leading: const AppIcon(Symbols.receipt_long_rounded, fill: 1),
            title: const Text('App logs'),
            trailing: const AppIcon(Symbols.chevron_right_rounded, fill: 1),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LogsScreen())),
          ),
        ],
      ),
      const SizedBox(height: 16),
      SettingsGroup(
        title: 'Changes made through the agent connection',
        margin: EdgeInsets.zero,
        children: [
          if (changes.isEmpty) _info(Symbols.check_circle_rounded, 'None', 'Nothing to undo.'),
          for (final change in changes) _info(Symbols.tune_rounded, change, null),
          if (changes.isNotEmpty)
            FocusableListTile(
              leading: const AppIcon(Symbols.undo_rounded, fill: 1),
              title: const Text('Undo all'),
              onTap: () async {
                final done = await DevChannel.revert();
                if (!context.mounted) return;
                setState(() {});
                await _showResult(context, 'Undone', done);
              },
            ),
        ],
      ),
      for (final group in DevActions.groups) ...[
        const SizedBox(height: 16),
        SettingsGroup(
          title: _groupTitles[group],
          margin: EdgeInsets.zero,
          children: [
            for (final action in DevActions.all.where((a) => a.group == group))
              FocusableListTile(
                leading: AppIcon(_groupIcons[group]!, fill: 1),
                title: Text(action.name),
                subtitle: Text(action.description),
                trailing: action.inputs.isEmpty ? null : const AppIcon(Symbols.edit_note_rounded, fill: 1),
                onTap: () => _run(context, action),
              ),
          ],
        ),
      ],
      const SizedBox(height: 24),
    ];
  }

  Widget _info(IconData icon, String title, String? subtitle, {VoidCallback? onTap}) => FocusableListTile(
    leading: AppIcon(icon, fill: 1),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    onTap: onTap ?? () {},
  );

  Future<void> _run(BuildContext context, DevAction action) async {
    var args = <String, dynamic>{};
    if (action.inputs.isNotEmpty) {
      final entered = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _ActionInputDialog(action: action),
      );
      if (entered == null) return;
      args = entered;
    }
    Object? result;
    try {
      result = await DevActions.run(action.name, args, fromPage: true);
    } catch (e) {
      result = {'error': '$e'};
    }
    if (!mounted) return;
    setState(() {});
    if (!context.mounted) return;
    await _showResult(context, action.name, result);
  }

  Future<void> _showResult(BuildContext context, String title, Object? result) {
    String text;
    try {
      text = const JsonEncoder.withIndent('  ').convert(result);
    } catch (_) {
      text = '$result';
    }
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
        ],
      ),
    );
  }
}

class _ActionInputDialog extends StatefulWidget {
  const _ActionInputDialog({required this.action});

  final DevAction action;

  @override
  State<_ActionInputDialog> createState() => _ActionInputDialogState();
}

class _ActionInputDialogState extends State<_ActionInputDialog> {
  late final Map<String, TextEditingController> _controllers = {
    for (final input in widget.action.inputs) input.name: TextEditingController(),
  };

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final args = <String, dynamic>{
      for (final entry in _controllers.entries)
        if (entry.value.text.trim().isNotEmpty) entry.key: entry.value.text.trim(),
    };
    Navigator.pop(context, args);
  }

  @override
  Widget build(BuildContext context) {
    final inputs = widget.action.inputs;
    return AlertDialog(
      title: Text(widget.action.name),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.action.description),
              for (var i = 0; i < inputs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextField(
                    controller: _controllers[inputs[i].name],
                    autofocus: i == 0,
                    decoration: InputDecoration(
                      labelText: '${inputs[i].name}${inputs[i].required ? ' *' : ''}',
                      helperText: inputs[i].choices == null
                          ? inputs[i].description
                          : '${inputs[i].description} (${inputs[i].choices!.join(' / ')})',
                      helperMaxLines: 3,
                    ),
                    onSubmitted: (_) => i == inputs.length - 1 ? _submit() : null,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Run')),
      ],
    );
  }
}
