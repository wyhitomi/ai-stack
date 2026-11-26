# VS Code integration

There are two complementary paths:

| Path | Extension | Talks to | Best for |
|---|---|---|---|
| **Continue** | `Continue.continue` | LiteLLM `:4000` (works from any LAN machine) | autocomplete, inline edits, quick chat, plus Hermes as a chat model |
| **ACP** | `formulahendry.acp-client` | `hermes acp` via `docker exec` | Hermes as a full in-editor agent: file diffs, terminal, approvals |

## Continue (every machine)

1. Install the **Continue** extension.
2. Copy `vscode/continue-config.yaml` to `~/.continue/config.yaml`. On Windows that's `%USERPROFILE%\.continue\config.yaml`.
3. Replace `AI_HOST` with the laptop's LAN IP for other machines on the home LAN, or `localhost` on the laptop itself.
4. Replace `sk-REPLACE_ME` with a key:
   - on the stack machine: `grep VSCODE_LLM_API_KEY .env`
   - for another person or laptop: `scripts/new-key.sh laptop-maria`, so each one has its own key, usage tracking and revocation in the LiteLLM UI.

Models you get in Continue:

- **Coder (local)**: direct model, fast. Use it for chat, `Ctrl+I` edits and Continue's agent mode.
- **Hermes Agent**: the orchestrator, with its own tools, skills and long-term memory. Use it for "investigate and fix", multi-step work, and anything where it should remember project decisions across sessions.
- **Autocomplete (local)**: ghost-text completions from the 1.5B FIM model.

If autocomplete inserts chat-style text ("Sure! Here's..."), the request went to the chat endpoint. Check that `useLegacyCompletionsEndpoint: true` is in the config, and that `scripts/doctor.sh` passes the FIM check.

## ACP: Hermes as the in-editor agent

1. Open your project **in WSL** (the "WSL" extension → *Connect to WSL*) and keep it under `WORKSPACE_DIR`. That directory is mounted at the same path inside the Hermes container, so the paths line up.
2. Install the **ACP Client** extension.
3. Merge block A from `vscode/settings.acp.jsonc` into your settings.json.
4. Open the ACP Client panel → **Hermes (ai-stack)** → Connect.

Hermes keeps its identity, memory, skills and the LiteLLM-routed model in ACP mode. File edits arrive as diffs, and terminal commands ask for approval in the panel.

## Which one when?

- Typing code: Continue autocomplete.
- "Rename this, add a test for that": Continue `Ctrl+I` with Coder.
- "Find why the build fails on CI and fix it": Hermes, via ACP (on the stack machine) or the Hermes Agent model in Continue (from anywhere).
