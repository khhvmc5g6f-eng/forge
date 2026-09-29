import '../protocol/messages.dart';

sealed class ChatItem {
  const ChatItem();
}

class UserItem extends ChatItem {
  const UserItem(this.text);
  final String text;
}

class AssistantItem extends ChatItem {
  const AssistantItem({
    this.text = '',
    this.reasoning = '',
    this.streaming = false,
  });
  final String text;
  final String reasoning;
  final bool streaming;

  AssistantItem copyWith({String? text, String? reasoning, bool? streaming}) =>
      AssistantItem(
        text: text ?? this.text,
        reasoning: reasoning ?? this.reasoning,
        streaming: streaming ?? this.streaming,
      );
}

class ToolItem extends ChatItem {
  const ToolItem({
    required this.id,
    required this.name,
    required this.status,
    this.input,
    this.output,
    this.error,
  });
  final String id;
  final String name;
  final ToolStatus status;
  final Object? input;
  final Object? output;
  final String? error;
}

class NoticeItem extends ChatItem {
  const NoticeItem(this.text, {this.isError = false});
  final String text;
  final bool isError;
}

/// Pure reducer from hub messages to a chat transcript (no I/O, fully testable).
class ChatTranscript {
  ChatTranscript([List<ChatItem>? items]) : _items = items ?? [];

  final List<ChatItem> _items;
  List<ChatItem> get items => List.unmodifiable(_items);

  void clear() => _items.clear();

  void addUser(String text) {
    _finishStreaming();
    _items.add(UserItem(text));
    _items.add(const AssistantItem(streaming: true));
  }

  void appendAssistant(String delta) {
    final i = _openAssistantIndex();
    final cur = _items[i] as AssistantItem;
    _items[i] = cur.copyWith(text: cur.text + delta);
  }

  void appendReasoning(String delta) {
    final i = _openAssistantIndex();
    final cur = _items[i] as AssistantItem;
    _items[i] = cur.copyWith(reasoning: cur.reasoning + delta);
  }

  void upsertTool(ToolEvent e, {required String fallbackText}) {
    final id = e.toolCallId ?? 'tool-${_items.length}';
    final item = ToolItem(
      id: id,
      name: e.toolName ?? (fallbackText.isEmpty ? 'tool' : fallbackText),
      status: e.status,
      input: e.input,
      output: e.output,
      error: e.error,
    );
    final at = _items.indexWhere((x) => x is ToolItem && x.id == id);
    if (at >= 0) {
      _items[at] = item;
      return;
    }
    // Keep tools ahead of the still-streaming assistant bubble.
    final open =
        _items.isNotEmpty &&
        _items.last is AssistantItem &&
        (_items.last as AssistantItem).streaming;
    if (open) {
      _items.insert(_items.length - 1, item);
    } else {
      _items.add(item);
    }
  }

  void addNotice(String text, {bool isError = false}) =>
      _items.add(NoticeItem(text, isError: isError));

  void finishTurn() {
    _finishStreaming();
    // Drop an empty trailing assistant placeholder.
    if (_items.isNotEmpty && _items.last is AssistantItem) {
      final a = _items.last as AssistantItem;
      if (a.text.isEmpty && a.reasoning.isEmpty) _items.removeLast();
    }
  }

  void hydrate(List<HistoryMessage> history) {
    _items.clear();
    for (final m in history) {
      switch (m.role) {
        case 'user':
          _items.add(UserItem(m.text));
        case 'assistant':
          for (final t in m.toolEvents) {
            _items.add(
              ToolItem(
                id: t.id,
                name: t.name,
                status: t.status,
                input: t.input,
                output: t.output,
                error: t.error,
              ),
            );
          }
          if (m.text.isNotEmpty || (m.reasoning ?? '').isNotEmpty) {
            _items.add(
              AssistantItem(text: m.text, reasoning: m.reasoning ?? ''),
            );
          }
        case 'error':
          _items.add(NoticeItem(m.text, isError: true));
        default:
          if (m.text.isNotEmpty) _items.add(NoticeItem(m.text));
      }
    }
  }

  int _openAssistantIndex() {
    if (_items.isNotEmpty &&
        _items.last is AssistantItem &&
        (_items.last as AssistantItem).streaming) {
      return _items.length - 1;
    }
    _items.add(const AssistantItem(streaming: true));
    return _items.length - 1;
  }

  void _finishStreaming() {
    for (var i = 0; i < _items.length; i++) {
      final it = _items[i];
      if (it is AssistantItem && it.streaming) {
        _items[i] = it.copyWith(streaming: false);
      }
    }
  }
}
