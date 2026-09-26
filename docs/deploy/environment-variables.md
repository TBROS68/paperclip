---
title: Environment Variables
summary: Full environment variable reference
---

All environment variables that Paperclip uses for server configuration.

## Server Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3100` | Server port |
| `PAPERCLIP_BIND` | `loopback` | Reachability preset: `loopback`, `lan`, `tailnet`, or `custom` |
| `PAPERCLIP_BIND_HOST` | (unset) | Required when `PAPERCLIP_BIND=custom` |
| `HOST` | `127.0.0.1` | Legacy host override; prefer `PAPERCLIP_BIND` for new setups |
| `DATABASE_URL` | (embedded) | PostgreSQL connection string |
| `PAPERCLIP_HOME` | `~/.paperclip` | Base directory for all Paperclip data |
| `PAPERCLIP_INSTANCE_ID` | `default` | Instance identifier (for multiple local instances) |
| `PAPERCLIP_DEPLOYMENT_MODE` | `local_trusted` | Runtime mode override |
| `PAPERCLIP_DEPLOYMENT_EXPOSURE` | `private` | Exposure policy when deployment mode is `authenticated` |
| `PAPERCLIP_API_URL` | (auto-derived) | Paperclip API base URL. When set externally (e.g., via Kubernetes ConfigMap, load balancer, or reverse proxy), the server preserves the value instead of deriving it from the listen host and port. Useful for deployments where the public-facing URL differs from the local bind address. |
| `PAPERCLIP_CHAT_WEBHOOK_PUBLIC_URL` | (board public origin) | Optional HTTPS origin for native chat provider webhooks when ingress and the board use different hosts. Must have no credentials, path, query, or fragment; invalid configuration refuses startup. Used only for provider callback URLs, not board links, authentication, trusted hosts, or identity confirmation. |
| `PAPERCLIP_RUNNER_PUBLIC_URL` | (unset) | Explicit `wss://` base URL used only when a remote `paperclip_runner` target dials Paperclip directly. Paperclip appends `/api/runner/v1/connect/<runId>`; the reverse proxy must forward WebSocket upgrades for that route. This value is never inferred from request headers. Daytona ignores it and uses provider ingress. |
| `PAPERCLIP_RUNNER_CA_BUNDLE_PATH` | (unset) | Optional PEM CA bundle for direct runner WSS. Platform roots remain enabled. There is no insecure TLS bypass. |
| `PAPERCLIP_RUNNER_REMOTE_BINARY_PATH` | (host build) | Host-local path to a `paperclip-runnerd` artifact built for the remote target OS and architecture. Required when Paperclip and the remote sandbox do not share a compatible platform; build metadata and the required transport mode are verified before launch. |
| `PAPERCLIP_RUNNER_REMOTE_CODEX_PATH` | (unset) | Optional host-local path to a Codex executable built for the remote target OS and architecture. For remote Codex-backed runners, Paperclip stages and verifies this executable beside `paperclip-runnerd`. |
| `PAPERCLIP_RUNNER_REMOTE_CODEX_NPM_SPEC` | (unset) | Optional pinned npm package spec (for example, `@openai/codex@0.156.0`) installed inside each fresh remote lease when its Codex harness is not baked into the sandbox image. Mutually exclusive with `PAPERCLIP_RUNNER_REMOTE_CODEX_PATH`; Paperclip verifies the installed executable before starting `runnerd`. |
| `PAPERCLIP_RUNNER_REMOTE_PROVIDER_PACK_PATH` | (unset) | Host-local path to the immutable provider pack built by `pnpm --filter @paperclipai/paperclip-runner build:provider-pack`. The pack includes its target-built Node 24.11 runtime, locked production dependencies, OpenCode proxy/executable, and ACPX sidecar. Remote OpenCode and ACPX fail closed without it. A preinstalled pack is accepted only when its complete digested manifest matches this build-owned pack; otherwise Paperclip stages this pack into the sandbox. |
| `PAPERCLIP_HIDDEN_SETTINGS` | (unset) | Comma-separated settings surfaces to hide from the UI and floor at the API, for operators hosting Paperclip for others (managed cloud, internal shared server). See [Hiding settings surfaces](#hiding-settings-surfaces). |
| `PAPERCLIP_SETTING_DEFAULTS` | (unset) | JSON object replacing the schema default of selected instance settings, for hosting operators. See [Operator setting defaults](#operator-setting-defaults). |

Daytona connectivity for `paperclip_runner` uses authenticated provider
WebSocket ingress and follows the instance experimental setting
`enableNativeRunner` (default `false`). There is no separate ingress opt-in.
Disabling Paperclip Runner blocks fresh native starts while persisted native
runs retain their recovery path. The deprecated `enableRunnerPreviewIngress`
key remains accepted in stored and managed configuration for version-skew
compatibility, but it has no runtime effect. The setting has no effect on
legacy adapters or callback bridges.

### Webhook-only chat ingress

Keep `PAPERCLIP_PUBLIC_URL` (or the explicit authentication public URL) pointed
at the actual board. If the board is private, set
`PAPERCLIP_CHAT_WEBHOOK_PUBLIC_URL=https://chat-ingress.example.com` and forward
only `POST /api/chat-webhooks/*` from that host. Provider signatures still gate
ingress; this variable does not expose routes or grant provider access.
Never forward the private `local_trusted` board through a public tunnel.

In Paperclip Cloud, chat callback URLs and account-linking URLs follow the
instance's signed canonical origin after a warm instance is claimed, without
requiring a restart. An explicit `PAPERCLIP_CHAT_WEBHOOK_PUBLIC_URL` still takes
precedence for provider callbacks only; board links follow the claimed origin.
Existing provider-side callback settings must be updated if they were created
with an old URL.

Task links in external messages require an externally safe HTTPS board URL.
Local/private board URLs are omitted with instructions to open the task in
Paperclip; the public webhook host is never substituted for the board. Identity
confirmation stays on the board and requires the user to be able to reach it.

### Preinstalled remote runner images

Remote sandbox images may preinstall `paperclip-runnerd`, `codex`, and the
provider pack at `/opt/paperclip-runner/provider-pack` instead of
paying the upload and npm-install cost on every fresh lease. Put both executable
names on the sandbox user's `PATH`; `$HOME/.local/bin` is checked explicitly
before `PATH`. Paperclip verifies runner build metadata, the selected PRP
transport capability, Codex startup, the provider-pack digest, exact harness
pins, Node compatibility, and packaged bridge digests before linking artifacts
into the run-specific runtime directory. A missing or incompatible executable falls back
to `PAPERCLIP_RUNNER_REMOTE_BINARY_PATH` and
`PAPERCLIP_RUNNER_REMOTE_CODEX_NPM_SPEC` (or
`PAPERCLIP_RUNNER_REMOTE_CODEX_PATH`) without changing the selected transport.
OpenCode and ACPX instead fall back only to
`PAPERCLIP_RUNNER_REMOTE_PROVIDER_PACK_PATH`; they never start a provider
process on the Paperclip host for a remote target.
The Daytona environment editor's **Configure image** action can create this
image without a separate container registry: install the executables in its
setup sandbox, finish setup, and Paperclip captures and promotes the resulting
Daytona snapshot for future leases.

### Hiding settings surfaces

`PAPERCLIP_HIDDEN_SETTINGS` takes keys from the registry in
`packages/shared/src/settings-visibility.ts`:

- Any instance settings page: `instance.profile`, `instance.environments`,
  `instance.access`, `instance.experimental`,
  `instance.plugins`, `instance.adapters` — removed from navigation and
  routing (the General page is the settings root and stays visible). Hiding
  `instance.access`, `instance.plugins`, or `instance.adapters` also floors
  their management endpoints with `403 settings_operator_managed`; hiding
  `instance.experimental` floors every experimental toggle write.
- Any Instance → General section: `instance.general.censorUsernameInLogs`,
  `instance.general.keyboardShortcuts`, `instance.general.backupRetention`,
  `instance.general.feedbackDataSharingPreference` (each also rejects
  value-changing writes via `PATCH /api/instance/settings/general`), plus the
  UI-only `instance.general.deploymentStatus` and `instance.general.signOut`.
- Any experimental toggle: `instance.experimental.<flagKey>` (e.g.
  `instance.experimental.enableSmokeLab`) — the card disappears and
  value-changing writes are rejected.
- All current and future experimental toggles: `instance.experimental.*`.
  Add `!instance.experimental.<flagKey>` entries to leave specific controls
  available. The server expands this policy against its own feature catalog,
  so new toggles stay hidden without an environment change. The Experimental
  page remains available. Exceptions only apply to the wildcard; an explicit
  hidden toggle or `instance.experimental` page restriction always wins,
  regardless of entry order. Unknown exceptions are logged and ignored.
- Any top-level company settings page: `company.members`, `company.invites`,
  `company.secrets`, `company.export`, `company.import` — removed from the
  settings sidebar, tab bar, and routing (the company General page is the
  settings root and stays visible). These are UI-visibility keys: the
  membership, invite, secret, and export APIs stay live for agents and
  integrations. `company.import` is the exception — hiding it also floors
  every company-import route with `403 settings_operator_managed`. On
  cloud-managed instances import is floored unconditionally with
  `403 cloud_managed`, independent of this variable.
- A single tab of the Secrets page: `company.secrets.vaults` (Provider
  vaults) and `company.secrets.proposals` (Proposals) — the tab disappears
  while the rest of the page stays up. UI-visibility only; the secret
  provider-config and proposal APIs stay live for agents and integrations.

- `workspaces.isolation` hides project execution-workspace policy, task and
  routine workspace selectors, pipeline workspace overrides, isolated re-issue
  actions, and the execution-workspace Configuration tab (including direct
  links). Workspace navigation, files, status, and runtime access stay available.
  This key only controls UI visibility: it does not disable isolation, change
  saved policies, or block APIs used by agents. New tasks and routine runs omit
  hidden draft overrides so the server applies the existing defaults. Tasks
  launched from a workspace or parent task keep that explicit context. Hide the two
  experimental isolation toggles separately when the operator manages them.

Unknown keys are logged and ignored, so one list can be rolled across a fleet
of mixed app versions, and retired keys (like `instance.heartbeats`, whose
page was removed) can stay in an operator list without breaking older or
newer releases. With the variable unset nothing is hidden and behavior
is identical to earlier releases. Hiding a toggle does not change its value;
pair hiding with the desired default where it matters (for general settings,
see [Operator setting defaults](#operator-setting-defaults)).

For example, this allows only the Environments control and keeps the Plugins
settings page hidden:

```sh
PAPERCLIP_HIDDEN_SETTINGS='instance.plugins,instance.experimental.*,!instance.experimental.enableEnvironments'
```

`GET /api/health` returns the expanded concrete keys in `hiddenSettings`.
The UI and settings API use the same restrictions. Reads and same-value
echoes remain allowed; changing a hidden value returns
`403 settings_operator_managed`.

Older images that predate wildcard support ignore the wildcard and exceptions.
Keep their explicit hidden-toggle entries during an upgrade, or upgrade all
images before replacing an explicit list. Once every image supports this
syntax, the wildcard and its exceptions are sufficient. A recognized exception
without a wildcard has no effect.

### Operator setting defaults

`PAPERCLIP_SETTING_DEFAULTS` takes a JSON object whose fields come from the
registry in `packages/shared/src/setting-defaults.ts` (currently
`feedbackDataSharingPreference`). The operator value substitutes for the
schema default at read time: any field whose effective value is still the
schema default resolves to the operator value, while an explicit non-default
user choice always wins. The overlay is never persisted, so unsetting the
variable restores stock behavior wherever a user has not chosen otherwise.
A client that writes back the full settings object it read does not persist
the operator value either: writing the operator value over a still-unchosen
field is treated as an echo of the overlay and the field stays unchosen.

Example: `PAPERCLIP_SETTING_DEFAULTS='{"feedbackDataSharingPreference":"allowed"}'`
defaults AI feedback sharing to allowed; pairing it with
`instance.general.feedbackDataSharingPreference` in `PAPERCLIP_HIDDEN_SETTINGS`
also hides the control and floors value-changing writes.

Unknown field names are logged and ignored (mixed-version fleet safe).
Malformed JSON or an invalid value for a known field refuses startup — policy
configuration fails closed.

## Secrets

| Variable | Default | Description |
|----------|---------|-------------|
| `PAPERCLIP_SECRETS_MASTER_KEY` | (from file) | 32-byte encryption key (base64/hex/raw) |
| `PAPERCLIP_SECRETS_MASTER_KEY_FILE` | `~/.paperclip/.../secrets/master.key` | Path to key file |
| `PAPERCLIP_SECRETS_STRICT_MODE` | `false` | Require secret refs for sensitive env vars |

## Agent Runtime (Injected into agent processes)

These are set automatically by the server when invoking agents:

| Variable | Description |
|----------|-------------|
| `PAPERCLIP_AGENT_ID` | Agent's unique ID |
| `PAPERCLIP_COMPANY_ID` | Company ID |
| `PAPERCLIP_API_URL` | Paperclip API base URL (inherits the server-level value; see Server Configuration above) |
| `PAPERCLIP_API_KEY` | Short-lived JWT for API auth |
| `PAPERCLIP_RUN_ID` | Current heartbeat run ID |
| `PAPERCLIP_TASK_ID` | Issue that triggered this wake |
| `PAPERCLIP_WAKE_REASON` | Wake trigger reason |
| `PAPERCLIP_WAKE_COMMENT_ID` | Comment that triggered this wake |
| `PAPERCLIP_APPROVAL_ID` | Resolved approval ID |
| `PAPERCLIP_APPROVAL_STATUS` | Approval decision |
| `PAPERCLIP_LINKED_ISSUE_IDS` | Comma-separated linked issue IDs |

## LLM Provider Keys (for adapters)

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | Anthropic API key (for Claude Code adapter) |
| `OPENAI_API_KEY` | OpenAI API key (for Codex adapter) |

### OpenAI-compatible gateways (Vilao, etc.)

Use any OpenAI-compatible `base_url` (a gateway, a proxy, or a model
marketplace such as Vilao AI at `https://api.vilao.ai/v1`) without authoring
provider JSON by hand. `OPENAI_BASE_URL` is a fallback that synthesizes the
same `openai_custom` provider for **both** adapters at once. The JSON envs are
always authoritative: when `PAPERCLIP_CODEX_PROVIDERS` (or
`PAPERCLIP_OPENCODE_PROVIDERS`) is set, the fallback is ignored, so operators
who need several providers, custom provider ids, or extra Codex/OpenCode
fields keep full control.

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENAI_BASE_URL` | (unset) | Generic OpenAI-compatible base URL fallback. When set and the corresponding `PAPERCLIP_*_PROVIDERS` JSON is absent, Paperclip synthesizes a single `openai_custom` provider backed by this URL. Example: `https://api.vilao.ai/v1` (Vilao AI). |
| `OPENAI_API_KEY_ENV` | `OPENAI_API_KEY` | Env var name that holds the bearer key for the synthesized `openai_custom` provider. Example: `VILAO_API_KEY` when the marketplace key is stored under that name. |
| `OPENAI_WIRE_API` | `responses` | Codex wire protocol for the synthesized provider. Use `chat_completions` when the gateway does not implement the Responses API. |
| `PAPERCLIP_CODEX_PROVIDERS` | (unset) | JSON `{ providers: { <id>: { name, base_url, env_key, wire_api, query_params, http_headers, ... } }, model_provider: "<id>" }` merged into `$CODEX_HOME/config.toml` as `[model_providers.<id>]` tables. Overrides `OPENAI_BASE_URL` when set. See `packages/adapters/codex-local/src/server/runtime-config.ts`. |
| `PAPERCLIP_OPENCODE_PROVIDERS` | (unset) | JSON `{ <id>: { npm: "@ai-sdk/openai-compatible", name, options: { baseURL, apiKey }, models: { "<model>": {} } } }` merged into the runtime `opencode.json` `provider` object. Overrides `OPENAI_BASE_URL` when set. See `packages/adapters/opencode-local/src/server/runtime-config.ts`. |
| `PAPERCLIP_OPENCODE_SMALL_MODEL` | (unset) | Pin OpenCode's auxiliary `small_model` (session-title helper) to an explicit `provider/model`. Set it to a model served by the gateway so the title-gen call does not fall back to an unsupported default. |

Quickstart (Vilao):

```sh
# One-line fallback (both adapters point at Vilao):
OPENAI_BASE_URL=https://api.vilao.ai/v1
OPENAI_API_KEY=sk-vilao-...            # or VILAO_API_KEY with OPENAI_API_KEY_ENV=VILAO_API_KEY
# then select a Vilao-served model in the agent:
#   codex_local  agent: model = "gpt-4o"                    (model_provider is openai_custom)
#   opencode_local agent: model = "openai_custom/gpt-4o"

# Full control via JSON (overrides the fallback):
PAPERCLIP_CODEX_PROVIDERS='{"providers":{"vilao":{"name":"Vilao","base_url":"https://api.vilao.ai/v1","env_key":"OPENAI_API_KEY","wire_api":"responses"}},"model_provider":"vilao"}'
PAPERCLIP_OPENCODE_PROVIDERS='{"vilao":{"npm":"@ai-sdk/openai-compatible","name":"Vilao","options":{"baseURL":"https://api.vilao.ai/v1","apiKey":"{env:OPENAI_API_KEY}"},"models":{"gpt-4o":{}}}}'
PAPERCLIP_OPENCODE_SMALL_MODEL=vilao/gpt-4o-mini
```

`{env:VAR}` placeholders under `PAPERCLIP_*_PROVIDERS` are expanded server-side
(retained for fields that must carry a literal value, such as OpenCode
`options.apiKey` or Codex `http_headers`).

### Vilao as a first-class AI provider

Vilao is also a **provider in the product**, not only an env-level fallback:
Settings → AI Keys lists *Vilao* alongside Claude, OpenAI, OpenRouter and
Grok, and the key is stored as `VILAO_API_KEY` (`AI_CONNECTION_CAPABILITIES.vilao`
in `packages/shared/src/ai-connections.ts`). Adding a Vilao connection to a
`codex_local` or `opencode_local` agent makes the server write, into that run's
environment, the routing the adapter needs:

| Written into the managed run | Value |
|-----------------------------|-------|
| `VILAO_API_KEY` | the stored key |
| `OPENAI_BASE_URL` | `https://api.vilao.ai/v1` |
| `OPENAI_API_KEY_ENV` | `VILAO_API_KEY` (the name the adapter should read) |

The adapter then synthesizes the same `openai_custom` Codex/OpenCode provider
as the env fallback, pointed at Vilao — so nothing has to be configured on the
host. Model names stay whatever Vilao serves: `gpt-4o` for `codex_local`,
`openai_custom/gpt-4o` for `opencode_local`.

## Secrets
