import 'package:flutter/material.dart';

import '../protocol/messages.dart';
import '../state/chat_items.dart';
import '../state/session_controller.dart';
import '../state/voice_controller.dart';

class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.controller, required this.voice});
  final SessionController controller;
  final VoiceController voice;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  SessionController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_scrollToEnd);
    widget.voice.addListener(_syncPartial);
  }

  void _syncPartial() {
    final p = widget.voice.partial;
    if (p.isNotEmpty && _input.text != p) {
      _input.text = p;
      _input.selection = TextSelection.collapsed(offset: p.length);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _send() {
    final err = c.send(_input.text);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    _input.clear();
  }

  @override
  void dispose() {
    c.removeListener(_scrollToEnd);
    widget.voice.removeListener(_syncPartial);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, widget.voice]),
      builder: (context, _) {
        final items = c.transcript.items;
        return Column(
          children: [
            if (c.banner != null)
              MaterialBanner(
                content: Text(c.banner!),
                actions: const [SizedBox.shrink()],
              ),
            Expanded(
              child: items.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Ask Cline to work on the project running on your Mac.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: items.length,
                      itemBuilder: (_, i) => _ItemTile(items[i]),
                    ),
            ),
            for (final a in c.approvals)
              _ApprovalCard(request: a, controller: c),
            if (c.lastUsage != null) _UsageLine(c.lastUsage!),
            _Composer(
              controller: c,
              input: _input,
              voice: widget.voice,
              onSend: _send,
            ),
          ],
        );
      },
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile(this.item);
  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (item) {
      case UserItem(:final text):
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: SelectableText(
              text,
              style: TextStyle(color: scheme.onPrimaryContainer),
            ),
          ),
        );
      case AssistantItem(:final text, :final reasoning, :final streaming):
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.92,
            ),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (reasoning.isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text(
                      'Reasoning',
                      style: TextStyle(fontSize: 12),
                    ),
                    children: [
                      Text(
                        reasoning,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                if (text.isNotEmpty) SelectableText(text),
                if (streaming && text.isEmpty)
                  const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        );
      case ToolItem():
        return _ToolTile(item as ToolItem);
      case NoticeItem(:final text, :final isError):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            text,
            style: TextStyle(color: isError ? scheme.error : scheme.outline),
            textAlign: TextAlign.center,
          ),
        );
    }
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile(this.tool);
  final ToolItem tool;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (tool.status) {
      ToolStatus.running => (Icons.hourglass_top, scheme.outline),
      ToolStatus.completed => (Icons.check_circle_outline, scheme.primary),
      ToolStatus.failed => (Icons.error_outline, scheme.error),
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text(
          tool.name,
          style: const TextStyle(fontFamily: 'Menlo', fontSize: 13),
        ),
        childrenPadding: const EdgeInsets.all(12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tool.input != null)
            SelectableText(
              'input: ${_clip(tool.input)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (tool.output != null)
            SelectableText(
              'output: ${_clip(tool.output)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (tool.error != null)
            SelectableText(
              'error: ${tool.error}',
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
        ],
      ),
    );
  }

  static String _clip(Object? v, [int max = 1500]) {
    final s = v is String ? v : v.toString();
    return s.length > max ? '${s.substring(0, max)}…' : s;
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.request, required this.controller});
  final ApprovalRequest request;
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final input = request.input?.toString() ?? '';
    return Card(
      color: scheme.tertiaryContainer,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Approve ${request.toolName}?',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (input.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  input.length > 400 ? '${input.substring(0, 400)}…' : input,
                  style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => controller.respondToApproval(
                    request.approvalId,
                    false,
                    reason: 'Denied from mobile',
                  ),
                  child: const Text('Deny'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () =>
                      controller.respondToApproval(request.approvalId, true),
                  child: const Text('Approve'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UsageLine extends StatelessWidget {
  const _UsageLine(this.usage);
  final Usage usage;
  @override
  Widget build(BuildContext context) {
    final cost = usage.totalCost;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        'Last turn: ${usage.inputTokens ?? 0} in / ${usage.outputTokens ?? 0} out tokens${cost != null && cost > 0 ? ' · est. \$${cost.toStringAsFixed(4)}' : ''}',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.input,
    required this.voice,
    required this.onSend,
  });
  final SessionController controller;
  final TextEditingController input;
  final VoiceController voice;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final busy = controller.turnInProgress;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton.filledTonal(
              tooltip: voice.listening ? 'Stop dictation' : 'Dictate',
              isSelected: voice.listening,
              onPressed: voice.toggleListening,
              icon: Icon(voice.listening ? Icons.mic : Icons.mic_none),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: input,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: '${controller.autonomy.label} · message Cline',
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20)),
                  ),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            busy
                ? IconButton.filled(
                    tooltip: 'Stop',
                    onPressed: controller.abort,
                    icon: const Icon(Icons.stop),
                  )
                : IconButton.filled(
                    tooltip: 'Send',
                    onPressed: onSend,
                    icon: const Icon(Icons.arrow_upward),
                  ),
          ],
        ),
      ),
    );
  }
}
