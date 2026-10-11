# Azure AI Foundry and Forge Cloud

Forge is moving to Microsoft Azure as a commercial platform. This document covers the two
optional pieces in the Flutter app and CLI. Both are off unless configured.

> Status: written without a Dart or Flutter toolchain in the authoring environment. The
> code and tests have not been compiled or run. Run `flutter analyze` and `flutter test`
> before relying on them. The Forge Cloud routes are a contract being implemented in
> another repository and have not been exercised against the real service.

## 1. Azure AI Foundry provider

`AzureFoundryProvider` (`lib/core/models/providers/azure_foundry_provider.dart`) extends
`OpenAiCompatibleProvider`, so request and response translation, streaming (SSE) and tool
calls behave exactly like the other OpenAI-compatible providers. It changes only URL
construction and authentication. Its provider id is `azure-foundry`, and it joins the
provider fleet (`allModelProvidersProvider`) only when an endpoint is configured.

### Configuration

Nothing is hard-coded. Variables are read from the process environment:

| Variable | Meaning | Default |
|---|---|---|
| `FORGE_AZURE_FOUNDRY_ENDPOINT` | Resource root, for example `https://<resource>.openai.azure.com/`. Unset means Azure is not configured. | unset |
| `FORGE_AZURE_FOUNDRY_DEPLOYMENTS` | Comma-separated deployment names offered to the router | empty |
| `FORGE_AZURE_FOUNDRY_API_VERSION` | `api-version` for deployment addressing | `2024-10-21` (a default only; set the version your resource supports) |
| `FORGE_AZURE_FOUNDRY_ADDRESSING` | `deployment` or `v1` | `deployment` |
| `FORGE_AZURE_FOUNDRY_V1_API_VERSION` | Optional `api-version` for `v1` addressing | omitted |
| `FORGE_AZURE_FOUNDRY_AUTH` | `api-key` or `bearer` (Microsoft Entra ID) | `api-key` |
| `FORGE_AZURE_FOUNDRY_API_KEY` | Resource key (fallback; see below) | unset |
| `FORGE_AZURE_FOUNDRY_BEARER_TOKEN` | Entra ID access token (fallback; see below) | unset |

Addressing modes:

- `deployment`: `{endpoint}/openai/deployments/{deployment}/chat/completions?api-version=...`
- `v1`: `{endpoint}/openai/v1/chat/completions`, with the deployment name sent as `model`

### Credentials

Credentials go through the existing `SecretsStore`, never a config file. The provider reads
the secret `azure_foundry_api_key` (key mode) or `azure_foundry_bearer_token` (bearer
mode) and only falls back to the environment variables above when the store is empty.
Keys are sent in the `api-key` header; Entra tokens as `Authorization: Bearer`. Forge does
not acquire Entra tokens itself: supply a current one, for example from
`az account get-access-token --resource https://cognitiveservices.azure.com`, and refresh
it when it expires. Secrets are never logged or placed in `ProviderConfig`.

### Models

No model is assumed to exist. The list is the configured deployments, merged with names
from an optional `extraModelSource` (intended to be the Forge Cloud catalogue). If that
source fails, the configured list is still returned. `healthCheck()` makes a real
authenticated request to the models endpoint.

## 2. Forge Cloud client

`lib/core/cloud/` is a small typed client for the Forge Azure backend.

| File | Role |
|---|---|
| `cloud_routes.dart` | All paths in one place, plus the expected request and response shapes |
| `money.dart` | `Money`: integer nano units (`BigInt`) plus currency; JSON as `{"nanos": "<string>", "currency": "GBP"}`; never a `double` |
| `cloud_models.dart` | Wallet, usage, catalogue, estimate and device-code models with explicit `fromJson` / `toJson` |
| `forge_cloud_client.dart` | HTTP client, bearer auth from the `SecretsStore` (`forge_cloud_token`), device-code sign-in with polling |
| `cloud_wallet_service.dart` | `CloudWalletService` for the UI, with a not-configured implementation |

Configuration: `FORGE_CLOUD_URL` (or the `forgeCloudUrlProvider` state at runtime). Unset
means cloud features are disabled, and the UI and `forge cloud` print "Forge Cloud not
configured".

Expected routes (change them in `cloud_routes.dart` only):

| Method and path | Purpose |
|---|---|
| `POST /api/forge-device-code-issue` | Start sign-in; returns device code, user code, verification URI, interval |
| `POST /api/forge-device-code-redeem` | Poll with the device code; returns `pending`, `approved` (with token), `denied` or `expired` |
| `GET /api/wallet/balance` | Wallet balance |
| `GET /api/usage/summary` | Month-to-date spend and recent usage rows |
| `GET /api/models` | Model catalogue with GBP rates per million tokens |
| `POST /api/estimate` | Cost estimate for a model and token counts |

The Wallet and usage panel (`lib/ui/panels/wallet_panel.dart`) shows balance, month-to-date
spend and the last ten usage rows. The CLI has a status command only (`forge cloud`); it
has no persistent secrets store, so it cannot hold a sign-in token yet. The app has no
sign-in screen yet either: `ForgeCloudClient.issueDeviceCode` and `pollDeviceCode` exist
but are not wired to the UI.

## 3. Offline and local-first behaviour

- With no `FORGE_AZURE_FOUNDRY_ENDPOINT` and no `FORGE_CLOUD_URL`, nothing changes:
  built-in local models (Ollama/LM Studio), bring-your-own-key providers (NVIDIA NIM, Groq,
  Cerebras, OpenRouter, Z.AI, Google, Anthropic, OpenAI) and the router work as before.
- The Azure provider issues no request until it is used or health-checked. The cloud client
  issues none until a wallet refresh or sign-in is requested.
- A cloud outage or missing sign-in surfaces as a message in the Wallet panel and does not
  affect agents, tasks or other providers.

## 4. Tests

- `test/core/models/azure_foundry_provider_test.dart`: URLs, headers, api-version,
  deployment and v1 addressing, key versus bearer, streaming, tool calls, model list
- `test/core/cloud/money_and_models_test.dart`: nano-string round trips, rejection of
  numeric amounts
- `test/core/cloud/cloud_wallet_service_test.dart`: wallet service and client with
  `MockClient` from `package:http/testing.dart`
- `test/ui/panels/wallet_panel_test.dart`: empty state, data, error, refresh
