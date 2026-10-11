import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge/core/models/chat_types.dart';
import 'package:forge/core/models/providers/azure_foundry_provider.dart';
import 'package:forge/core/security/secrets_store.dart';

const _completion = {
  'choices': [
    {
      'message': {'role': 'assistant', 'content': 'hello'},
      'finish_reason': 'stop',
    }
  ],
  'usage': {'prompt_tokens': 3, 'completion_tokens': 1},
};

ChatRequest _request({List<ToolSpec> tools = const []}) => ChatRequest(
      messages: const [ChatMessage.user('hi')],
      tools: tools,
    );

AzureFoundrySettings _settings({
  AzureAddressing addressing = AzureAddressing.deployment,
  AzureAuthMode authMode = AzureAuthMode.apiKey,
  String? v1ApiVersion,
  List<String> deployments = const ['dep-a'],
}) =>
    AzureFoundrySettings(
      endpoint: Uri.parse('https://example-resource.openai.azure.com/'),
      deployments: deployments,
      apiVersion: '2099-01-01',
      v1ApiVersion: v1ApiVersion,
      addressing: addressing,
      authMode: authMode,
    );

void main() {
  group('request building', () {
    test('deployment addressing sends api-version, api-key and the deployment path',
        () async {
      final store = InMemorySecretsStore();
      await store.write('azure_foundry_api_key', 'test-key');
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(jsonEncode(_completion), 200);
      });
      final provider = AzureFoundryProvider(
        secretsStore: store,
        settings: _settings(),
        httpClient: client,
      );

      final result = await provider.chat('dep-a', _request());

      expect(seen.method, 'POST');
      expect(
        seen.url.toString(),
        'https://example-resource.openai.azure.com/openai/deployments/dep-a/chat/completions?api-version=2099-01-01',
      );
      expect(seen.headers['api-key'], 'test-key');
      expect(seen.headers.containsKey('Authorization'), isFalse);
      expect(seen.headers['Content-Type'], contains('application/json'));
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['stream'], false);
      expect(body['messages'], isA<List<dynamic>>());
      expect(result.message.content, 'hello');
      expect(result.finishReason, FinishReason.stop);
      expect(result.usage.promptTokens, 3);
    });

    test('deployment names are URL-encoded', () {
      final provider = AzureFoundryProvider(
        secretsStore: InMemorySecretsStore(),
        settings: _settings(),
      );
      expect(
        provider.chatUrl('my dep/1').path,
        '/openai/deployments/my%20dep%2F1/chat/completions',
      );
    });

    test('v1 addressing omits api-version by default and passes the model in the body',
        () async {
      final store = InMemorySecretsStore();
      await store.write('azure_foundry_api_key', 'test-key');
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(jsonEncode(_completion), 200);
      });
      final provider = AzureFoundryProvider(
        secretsStore: store,
        settings: _settings(addressing: AzureAddressing.v1),
        httpClient: client,
      );

      await provider.chat('dep-a', _request());

      expect(
        seen.url.toString(),
        'https://example-resource.openai.azure.com/openai/v1/chat/completions',
      );
      expect(seen.url.queryParameters, isEmpty);
      expect(seen.headers['api-key'], 'test-key');
      expect((jsonDecode(seen.body) as Map<String, dynamic>)['model'], 'dep-a');
    });

    test('v1 addressing includes api-version only when configured', () {
      final provider = AzureFoundryProvider(
        secretsStore: InMemorySecretsStore(),
        settings:
            _settings(addressing: AzureAddressing.v1, v1ApiVersion: 'preview'),
      );
      expect(provider.chatUrl('dep-a').queryParameters,
          {'api-version': 'preview'});
      expect(provider.modelsUrl().path, '/openai/v1/models');
    });

    test('models URL in deployment mode carries api-version', () {
      final provider = AzureFoundryProvider(
        secretsStore: InMemorySecretsStore(),
        settings: _settings(),
      );
      expect(provider.modelsUrl().toString(),
          'https://example-resource.openai.azure.com/openai/models?api-version=2099-01-01');
    });

    test('bearer mode sends Authorization and no api-key header', () async {
      final store = InMemorySecretsStore();
      await store.write('azure_foundry_bearer_token', 'entra-token');
      await store.write('azure_foundry_api_key', 'ignored-key');
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(jsonEncode(_completion), 200);
      });
      final provider = AzureFoundryProvider(
        secretsStore: store,
        settings: _settings(authMode: AzureAuthMode.bearer),
        httpClient: client,
      );

      await provider.chat('dep-a', _request());

      expect(seen.headers['Authorization'], 'Bearer entra-token');
      expect(seen.headers.containsKey('api-key'), isFalse);
    });

    test('falls back to the supplied environment when the store is empty',
        () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(jsonEncode(_completion), 200);
      });
      final provider = AzureFoundryProvider(
        secretsStore: InMemorySecretsStore(),
        settings: _settings(),
        environment: const {'FORGE_AZURE_FOUNDRY_API_KEY': 'env-key'},
        httpClient: client,
      );

      await provider.chat('dep-a', _request());
      expect(seen.headers['api-key'], 'env-key');
    });

    test('sends no credential header when none is configured', () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(jsonEncode(_completion), 200);
      });
      final provider = AzureFoundryProvider(
        secretsStore: InMemorySecretsStore(),
        settings: _settings(),
        httpClient: client,
      );

      await provider.chat('dep-a', _request());
      expect(seen.headers.containsKey('api-key'), isFalse);
      expect(seen.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('tool calls and streaming', () {
    test('chat parses tool calls like the OpenAI-compatible provider', () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect((body['tools'] as List<dynamic>).length, 1);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': null,
                  'tool_calls': [
                    {
                      'id': 'call_1',
                      'type': 'function',
                      'function': {
                        'name': 'read_file',
                        'arguments': '{"path":"a.txt"}',
                      },
                    }
                  ],
                },
                'finish_reason': 'tool_calls',
              }
            ],
          }),
          200,
        );
      });
      final provider = AzureFoundryProvider(
        secretsStore: InMemorySecretsStore(),
        settings: _settings(),
        httpClient: client,
      );

      final result = await provider.chat(
        'dep-a',
        _request(tools: const [
          ToolSpec(
            name: 'read_file',
            description: 'Read a file',
            parametersSchema: {'type': 'object'},
          ),
        ]),
      );

      expect(result.finishReason, FinishReason.toolCalls);
      expect(result.message.toolCalls.single.name, 'read_file');
      expect(result.message.toolCalls.single.arguments['path'], 'a.txt');
    });

    test('streamChat uses the deployment URL and yields content deltas',
        () async {
      late http.BaseRequest seen;
      const sse = 'data: {"choices":[]}\n\n'
          'data: {"choices":[{"delta":{"content":"he"}}]}\n\n'
          'data: {"choices":[{"delta":{"content":"llo"},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n';
      final client = MockClient.streaming((request, bodyStream) async {
        seen = request;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sse)),
          200,
        );
      });
      final provider = AzureFoundryProvider(
        secretsStore: InMemorySecretsStore(),
        settings: _settings(),
        httpClient: client,
      );

      final chunks = await provider.streamChat('dep-a', _request()).toList();

      expect(seen.url.path, '/openai/deployments/dep-a/chat/completions');
      expect(seen.url.queryParameters['api-version'], '2099-01-01');
      expect(chunks.map((c) => c.deltaContent).join(), 'hello');
      expect(chunks.last.finishReason, FinishReason.stop);
    });
  });

  group('model list and health', () {
    test('lists configured deployments and merges catalogue names without duplicates',
        () async {
      final provider = AzureFoundryProvider(
        secretsStore: InMemorySecretsStore(),
        settings: _settings(deployments: const ['dep-a', 'dep-b']),
        extraModelSource: () async => ['dep-b', 'dep-c', ''],
      );

      final models = await provider.listModels();

      expect(models.map((m) => m.id.modelName), ['dep-a', 'dep-b', 'dep-c']);
      expect(models.every((m) => m.id.providerId == 'azure-foundry'), isTrue);
    });

    test('a failing catalogue source does not hide configured deployments',
        () async {
      final provider = AzureFoundryProvider(
        secretsStore: InMemorySecretsStore(),
        settings: _settings(),
        extraModelSource: () async => throw StateError('offline'),
      );

      final models = await provider.listModels();
      expect(models.map((m) => m.id.modelName), ['dep-a']);
    });

    test('no configured models and no catalogue yields an empty list', () async {
      final provider = AzureFoundryProvider(
        secretsStore: InMemorySecretsStore(),
        settings: _settings(deployments: const []),
      );
      expect(await provider.listModels(), isEmpty);
    });

    test('healthCheck reflects the HTTP status of a real request', () async {
      Future<bool> check(int status) {
        final provider = AzureFoundryProvider(
          secretsStore: InMemorySecretsStore(),
          settings: _settings(),
          httpClient: MockClient((_) async => http.Response('{}', status)),
        );
        return provider.healthCheck();
      }

      expect(await check(200), isTrue);
      expect(await check(401), isFalse);
    });
  });

  group('AzureFoundrySettings.fromEnvironment', () {
    test('returns null when the endpoint is unset or invalid', () {
      expect(AzureFoundrySettings.fromEnvironment(const {}), isNull);
      expect(
        AzureFoundrySettings.fromEnvironment(
            const {'FORGE_AZURE_FOUNDRY_ENDPOINT': 'not a url'}),
        isNull,
      );
    });

    test('parses every variable and normalises the endpoint', () {
      final settings = AzureFoundrySettings.fromEnvironment(const {
        'FORGE_AZURE_FOUNDRY_ENDPOINT': 'https://r.services.ai.azure.com',
        'FORGE_AZURE_FOUNDRY_DEPLOYMENTS': ' a, b ,,c ',
        'FORGE_AZURE_FOUNDRY_API_VERSION': '2099-02-02',
        'FORGE_AZURE_FOUNDRY_V1_API_VERSION': 'preview',
        'FORGE_AZURE_FOUNDRY_ADDRESSING': 'v1',
        'FORGE_AZURE_FOUNDRY_AUTH': 'bearer',
      })!;

      expect(settings.endpoint.toString(), 'https://r.services.ai.azure.com/');
      expect(settings.deployments, ['a', 'b', 'c']);
      expect(settings.apiVersion, '2099-02-02');
      expect(settings.v1ApiVersion, 'preview');
      expect(settings.addressing, AzureAddressing.v1);
      expect(settings.authMode, AzureAuthMode.bearer);
    });

    test('defaults to deployment addressing, api-key auth and the default api-version',
        () {
      final settings = AzureFoundrySettings.fromEnvironment(const {
        'FORGE_AZURE_FOUNDRY_ENDPOINT': 'https://r.openai.azure.com/',
      })!;

      expect(settings.addressing, AzureAddressing.deployment);
      expect(settings.authMode, AzureAuthMode.apiKey);
      expect(settings.apiVersion, AzureFoundrySettings.defaultApiVersion);
      expect(settings.deployments, isEmpty);
    });
  });
}
