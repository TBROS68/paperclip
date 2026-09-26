/** Redacted presentation contracts shared with the production API. */
import {
  AI_CONNECTION_CAPABILITIES,
  type AiProvider,
  type AiAuthMethod,
  type AiManagedConnectionSummary,
  type AiConnectionBinding,
} from "@paperclipai/shared";
export type { AiProvider, AiAuthMethod, AiConnectionBinding } from "@paperclipai/shared";
export type AiConnectionStatus = AiManagedConnectionSummary["status"];

export const AI_PROVIDERS: Record<
  AiProvider,
  { name: string; subscriptionName?: string; logo?: string; darkLogo?: string }
> = {
  anthropic: {
    name: "Claude",
    subscriptionName: "Claude subscription",
    logo: "/brands/claude-color.svg",
  },
  openai: {
    name: "OpenAI",
    subscriptionName: "ChatGPT subscription",
    logo: "/brands/codex-color.svg",
  },
  openrouter: { name: "OpenRouter", logo: "/brands/apps/openrouter.svg" },
  xai: {
    name: "Grok",
    subscriptionName: "Grok subscription",
    logo: "/brands/adapters/grok.svg",
    darkLogo: "/brands/adapters/grok-dark.svg",
  },
  vilao: {
    name: "Vilao",
    logo: "/brands/apps/vilao.svg",
    darkLogo: "/brands/apps/vilao-dark.svg",
  },
};

export type AiConnectionSummary = Omit<AiManagedConnectionSummary, "isDefault"> & { isDefault?: boolean };

export interface AiConnectionRequirement {
  companyId: string;
  provider: AiProvider;
  method?: AiAuthMethod;
}

export const AI_CONNECTION_STATUS: Record<AiConnectionStatus, string> = {
  connected: "Connected",
  needs_attention: "Needs attention",
  expired: "Expired",
  revoked: "Revoked",
};

export type SubscriptionAdapterType = "claude_local" | "codex_local" | "grok_local";

/** The CLI that signs in to this provider, or undefined when the provider is
 * reached with an API key only. Read from the shared capability table so a new
 * provider never needs another branch in the connection flow. */
export function subscriptionAdapter(provider: AiProvider): SubscriptionAdapterType | undefined {
  const adapter = AI_CONNECTION_CAPABILITIES[provider].methods.subscription?.adapters[0];
  return adapter === "claude_local" || adapter === "codex_local" || adapter === "grok_local"
    ? adapter
    : undefined;
}

/** How a provider is connected when nothing else says otherwise. */
export function defaultAiMethod(provider: AiProvider): AiAuthMethod {
  return subscriptionAdapter(provider) ? "subscription" : "api_key";
}

/** OpenCode's model list comes from whichever provider owns the connection, so
 * every provider that routes to OpenCode — not just one — names it here. */
export function opencodeModelProvider(provider?: AiProvider): AiProvider | undefined {
  if (!provider) return undefined;
  return Object.values(AI_CONNECTION_CAPABILITIES[provider].methods).some((method) =>
    method?.adapters.includes("opencode_local")) ? provider : undefined;
}

/** The provider an adapter falls back to when the agent has not chosen one. */
const ADAPTER_PROVIDER_DEFAULTS: Record<string, AiProvider> = {
  claude_local: "anthropic",
  codex_local: "openai",
  opencode_local: "openrouter",
  grok_local: "xai",
};

/** Every provider this adapter can be reached through, the adapter's usual one
 * first. A gateway that speaks the same protocol is a peer of the vendor it
 * stands in for, so the choice belongs to whoever configures the agent. */
export function aiProvidersForAdapter(adapterType: string): AiProvider[] {
  const supported = (Object.keys(AI_PROVIDERS) as AiProvider[]).filter((provider) =>
    Object.values(AI_CONNECTION_CAPABILITIES[provider].methods).some((method) =>
      method?.adapters.includes(adapterType)));
  const preferred = ADAPTER_PROVIDER_DEFAULTS[adapterType];
  return preferred && supported.includes(preferred)
    ? [preferred, ...supported.filter((provider) => provider !== preferred)]
    : supported;
}

export function aiProviderForAdapter(adapterType: string): AiProvider | undefined {
  return aiProvidersForAdapter(adapterType)[0];
}

export function aiMethodLabel(provider: AiProvider, method: AiAuthMethod) {
  return method === "subscription"
    ? (AI_PROVIDERS[provider].subscriptionName ?? "Subscription unavailable")
    : "API key";
}

export function matchesAiRequirement(
  connection: AiConnectionSummary,
  requirement: AiConnectionRequirement,
) {
  return (
    connection.companyId === requirement.companyId &&
    connection.provider === requirement.provider &&
    (requirement.method === undefined || connection.method === requirement.method)
  );
}

export function personalAiDefault(
  connections: AiConnectionSummary[],
  requirement: AiConnectionRequirement,
  userId: string,
) {
  // Never choose another account because the declared default is unhealthy.
  return connections.find(
    (connection) =>
      matchesAiRequirement(connection, { ...requirement, method: undefined }) &&
      connection.ownership === "personal" &&
      connection.ownerUserId === userId &&
      connection.isDefault,
  );
}

export function aiConnectionProblem(connection?: AiConnectionSummary) {
  if (!connection)
    return "No connection selected. Connect an account to continue.";
  return (
    connection.unavailableReason ??
    (connection.status === "connected"
      ? null
      : `${AI_CONNECTION_STATUS[connection.status]}. Reconnect this account to continue.`)
  );
}

export function bindingProblem(
  binding: AiConnectionBinding,
  requirement: AiConnectionRequirement,
  connections: AiConnectionSummary[],
  userId: string,
  _agentId: string,
) {
  if (
    binding.provider !== requirement.provider ||
    (binding.mode !== "responsible_user" && requirement.method !== undefined && binding.method !== requirement.method)
  )
    return "Choose a connection compatible with this provider and sign-in method.";
  if (binding.mode === "responsible_user")
    return aiConnectionProblem(
      personalAiDefault(connections, requirement, userId),
    );
  const connection = connections.find(
    (item) =>
      item.id === binding.connectionId &&
      item.grantId === binding.grantId &&
      item.method === binding.method &&
      matchesAiRequirement(item, requirement),
  );
  if (!connection)
    return "This connection is no longer available for this agent. Choose another connection.";
  if (binding.mode === "shared" && connection.ownership !== "shared")
    return "Choose a company-shared connection.";
  if (
    binding.mode === "delegated" &&
    (connection.ownership !== "personal" ||
      connection.ownerUserId !== userId)
  )
    return "This credential is not shared with you. Choose a connection you can use.";
  return aiConnectionProblem(connection);
}
