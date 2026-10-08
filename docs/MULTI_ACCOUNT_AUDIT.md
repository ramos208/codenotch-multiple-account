# Multi-account provider audit

This is the implementation ledger for account isolation. “Blocked” means no
legitimate independent renewable credential mechanism has yet been verified;
it does not mean a second entry may reuse the active application's credential.

| Provider | Current auth source | Usage source | Refresh | Isolation / status |
|---|---|---|---|---|
| OpenAI / Codex | Codex `auth.json` | OpenAI usage endpoints | Codex OAuth refresh | Implemented: one `CODEX_HOME` per account |
| Anthropic / Claude | Claude config + Keychain | Anthropic OAuth usage | Claude OAuth refresh | Implemented: one `CLAUDE_CONFIG_DIR` and credential per account |
| Google / Antigravity | OAuth credential | Cloud Code Assist | OAuth refresh token | Implemented: one Keychain OAuth record per account |
| DeepSeek | Codenotch WebKit session | DeepSeek console APIs | Website session | Implemented: UUID WebKit data store per account |
| QianwenAI | Codenotch WebKit session | Qianwen console RPC | Website session | Implemented: UUID WebKit data store per account |
| MiniMax (web) | Codenotch WebKit session | MiniMax console | Website session | Implemented: UUID WebKit data store per account |
| MiniMax (key/cookie) | Codenotch Keychain | MiniMax API/console | Static key or cookie | Pending account-scoped Keychain records |
| Cursor | Cursor editor or isolated Cursor Agent | Cursor usage summary | Cursor Agent access + refresh token | Implemented: managed Agent login runs with a private HOME, `CURSOR_CONFIG_DIR`, and official file credential store; Cursor.app remains unchanged |
| Amp | Amp secrets file or Codenotch Keychain API key | Amp usage API | Static key | Implemented for managed accounts: one Keychain item and provider instance per account; legacy CLI account remains available |
| Apify | CLI/config token or Codenotch Keychain | Apify account API | Static token | Implemented for managed accounts: one Keychain token and provider instance per account; legacy CLI account remains available |
| Command Code | CLI auth file | Command Code API | Credential in auth file | Pending verified isolated CLI config mechanism |
| Devin | Desktop SQLite or CLI credential | Devin usage API | Owning client | Pending provider-supported profile/config isolation |
| GLM / Z.ai | Tool API key | Z.ai monitor API | Static key | Implemented: one Keychain item and provider instance per account, with Global/China region metadata |
| Gemini API | No credential is read | Aggregated Gemini/OpenCode/Hermes logs | None | Not separable by account: source logs contain token counts but no key/account identity; excluded rather than fabricating attribution |
| GitHub Copilot | GitHub CLI token or Codenotch Keychain token | Copilot internal user API | Static token / owning CLI | Implemented for managed tokens: one Keychain item and provider instance per account; legacy GitHub CLI account remains available |
| Grok | Per-account `GROK_HOME/auth.json` | Grok billing API | OAuth refresh token | Implemented with the official `GROK_HOME` isolation; the normal CLI session is unchanged |
| Kilo | Kilo CLI auth file or Codenotch Keychain API key | Kilo Cloud APIs | Static key; CLI owns OAuth refresh | Implemented for managed API-key accounts: one Keychain item and provider instance per account; OAuth copying is intentionally excluded |
| Kimi | Per-account `KIMI_CODE_HOME/credentials/kimi-code.json` | Kimi usage API | OAuth refresh token with atomic rotation | Implemented with the official `KIMI_CODE_HOME` isolation; the normal CLI session is unchanged |
| Kiro | Kiro SQLite/CLI | Kiro quota endpoint | Owning client | Disabled with an explicit blocker: browser/device login exists, but no provider-documented isolated profile root was found; `KIRO_DATA_DIR` is not treated as a public authentication contract |
| Ollama Cloud | Codenotch Keychain API key | Ollama usage API | Static key | Implemented: one Keychain item and provider instance per account |
| OpenCode | OpenCode auth file or Codenotch Keychain Go key | Provider-specific usage API | Static Go key / owning CLI OAuth | Implemented for managed Go keys: one Keychain item and provider instance per account; copied OAuth sessions are excluded |
| Custom endpoint | User-created endpoint credential | Configured API | Configured credential | Already multi-account: every endpoint has its own ID/configuration |
| Perplexity | WebKit adapter exists but is not registered | Perplexity web API | Website session | Adapter can use UUID WebKit stores; product registration decision pending |
| Ollama Local | No account | Local runtime | None | Not account-based; excluded |
| LM Studio Local | Optional local server token | Local runtime | Static local token | Runtime connection, not a hosted account; excluded |

Every implemented account is keyed by its account-level provider ID throughout
preferences, refresh tasks, snapshots, archives, menu items, and errors.
