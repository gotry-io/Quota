import { homedir } from "node:os";
import {
  ProviderCollectionError,
  type CollectionContext,
  type ProviderCollector,
  type ProviderSession,
} from "@gotry-io/provider-core";
import type { QuotaSnapshot } from "@gotry-io/quota-protocol";
import { classifyProviderError } from "../../runtime/errors.ts";
import {
  createFetchTransport,
  HttpRequestError,
  type HttpTransport,
  readJsonObject,
} from "../../runtime/http.ts";
import {
  CLAUDE_SOURCE_API,
  hasUserProfileScope,
  loadClaudeCredentials,
  type ClaudeCredentials,
} from "./credentials.ts";
import {
  buildClaudeSnapshot,
  claudePlanLabel,
  mapClaudeProfile,
  mapClaudeUsageResponse,
} from "./map.ts";

const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";
const PROFILE_URL = "https://api.anthropic.com/api/oauth/profile";
const BETA_HEADER = "oauth-2025-04-20";
const CLAUDE_USER_AGENT = "claude-code/2.1.0";

export interface ClaudeCollectorOptions {
  homeDirectory?: string;
  environment?: Readonly<Record<string, string | undefined>>;
  platform?: NodeJS.Platform;
  transport?: HttpTransport;
  readJson?: (path: string) => Promise<unknown | undefined>;
  readKeychain?: (service: string) => Promise<string | undefined>;
}

export class ClaudeCollector implements ProviderCollector {
  readonly provider = "claude" as const;
  private readonly homeDirectory: string;
  private readonly environment: Readonly<Record<string, string | undefined>>;
  private readonly platform: NodeJS.Platform;
  private readonly transport: HttpTransport;
  private readonly readJson: ClaudeCollectorOptions["readJson"];
  private readonly readKeychain: ClaudeCollectorOptions["readKeychain"];

  constructor(options: ClaudeCollectorOptions = {}) {
    this.homeDirectory = options.homeDirectory ?? homedir();
    this.environment = options.environment ?? process.env;
    this.platform = options.platform ?? process.platform;
    this.transport = options.transport ?? createFetchTransport();
    this.readJson = options.readJson;
    this.readKeychain = options.readKeychain;
  }

  async discover(): Promise<ProviderSession[]> {
    const credentials = await loadClaudeCredentials({
      homeDirectory: this.homeDirectory,
      environment: this.environment,
      platform: this.platform,
      ...(this.readJson ? { readJson: this.readJson } : {}),
      ...(this.readKeychain ? { readKeychain: this.readKeychain } : {}),
    });
    if (!credentials) {
      return [];
    }
    return [
      {
        provider: "claude",
        session_id: "ambient",
        display_label: "Claude Code",
        credential_source: credentials.source,
      },
    ];
  }

  async collect(
    _session: ProviderSession,
    context: CollectionContext = {},
  ): Promise<QuotaSnapshot> {
    const credentials = await loadClaudeCredentials({
      homeDirectory: this.homeDirectory,
      environment: this.environment,
      platform: this.platform,
      ...(context.signal ? { signal: context.signal } : {}),
      ...(this.readJson ? { readJson: this.readJson } : {}),
      ...(this.readKeychain ? { readKeychain: this.readKeychain } : {}),
    });
    if (!credentials) {
      throw new ProviderCollectionError(
        "auth_required",
        "Claude OAuth credentials are missing or unreadable. Run `claude auth login`.",
        CLAUDE_SOURCE_API,
      );
    }
    if (!hasUserProfileScope(credentials)) {
      throw new ProviderCollectionError(
        "auth_required",
        "Claude OAuth token missing 'user:profile' scope. Run `claude auth login`.",
        CLAUDE_SOURCE_API,
      );
    }

    const now = context.now ?? new Date();
    try {
      const usage = await this.fetchUsage(credentials, context.signal);
      const mapped = mapClaudeUsageResponse(usage);
      if (!mapped.usable) {
        throw new ProviderCollectionError(
          "unavailable",
          "Claude usage API returned no quota windows.",
          CLAUDE_SOURCE_API,
        );
      }

      let email: string | undefined;
      let organizationId: string | undefined;
      try {
        const profile = await this.fetchProfile(credentials, context.signal);
        const mappedProfile = mapClaudeProfile(profile);
        email = mappedProfile.email;
        organizationId = mappedProfile.organizationId;
      } catch {
        // Profile enrichment is best-effort; usage success must not be discarded.
      }

      const plan = claudePlanLabel(credentials.subscriptionType, credentials.rateLimitTier);
      return buildClaudeSnapshot({
        windows: mapped.windows,
        now,
        ...(plan ? { plan } : {}),
        ...(email ? { email } : {}),
        ...(organizationId ? { organizationId } : {}),
      });
    } catch (error) {
      const classified = classifyProviderError(error);
      throw new ProviderCollectionError(
        classified.category,
        classified.message,
        classified.source ?? CLAUDE_SOURCE_API,
      );
    }
  }

  private async fetchUsage(credentials: ClaudeCredentials, signal?: AbortSignal): Promise<unknown> {
    const { status, json, bodyText } = await readJsonObject(this.transport, {
      url: USAGE_URL,
      headers: {
        Authorization: `Bearer ${credentials.accessToken}`,
        Accept: "application/json",
        "anthropic-beta": BETA_HEADER,
        "User-Agent": CLAUDE_USER_AGENT,
      },
      ...(signal ? { signal } : {}),
    });

    if (status === 401) {
      throw new ProviderCollectionError(
        "auth_required",
        "Claude OAuth request unauthorized. Run `claude auth login` to re-authenticate.",
        CLAUDE_SOURCE_API,
      );
    }
    if (status === 403 && bodyText.toLowerCase().includes("user:profile")) {
      throw new ProviderCollectionError(
        "auth_required",
        "Claude OAuth token does not meet scope requirement 'user:profile'.",
        CLAUDE_SOURCE_API,
      );
    }
    if (status === 429) {
      throw new ProviderCollectionError(
        "unavailable",
        "Claude OAuth usage endpoint is rate limited. Wait a few minutes and retry.",
        CLAUDE_SOURCE_API,
      );
    }
    if (status < 200 || status >= 300) {
      throw new HttpRequestError(`Claude usage API returned HTTP ${status}.`, status);
    }
    return json;
  }

  private async fetchProfile(
    credentials: ClaudeCredentials,
    signal?: AbortSignal,
  ): Promise<unknown> {
    const { status, json } = await readJsonObject(this.transport, {
      url: PROFILE_URL,
      headers: {
        Authorization: `Bearer ${credentials.accessToken}`,
        Accept: "application/json",
      },
      ...(signal ? { signal } : {}),
    });
    if (status < 200 || status >= 300) {
      throw new HttpRequestError(`Claude profile API returned HTTP ${status}.`, status);
    }
    return json;
  }
}
