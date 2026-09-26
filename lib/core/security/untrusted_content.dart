/// Where content originated. Anything other than [ContentSource.user] is
/// treated as data, never as instructions, per SECURITY.md — a model output,
/// terminal stdout, or MCP resource can *describe* a request but must never
/// be allowed to *become* one without passing back through the
/// [PolicyEngine].
enum ContentSource {
  user,
  modelOutput,
  toolResult,
  terminalOutput,
  mcpResource,
  webContent,
  fileContent,
}

/// Wraps any content that entered Forge from outside a direct, explicit user
/// instruction. The Orchestrator and Agent layers only accept
/// [UntrustedContent] from tool execution — never a raw [String] — so that
/// "this tool result told me to run `rm -rf /`" cannot silently become an
/// executed action; only a [PolicyEngine] decision can authorise an action,
/// and the engine never reads content, only structured [ToolInvocation]s.
class UntrustedContent {
  const UntrustedContent({required this.source, required this.body});

  final ContentSource source;
  final String body;

  @override
  String toString() => '[$source] $body';
}
