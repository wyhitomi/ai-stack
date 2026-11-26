# ai-stack

A self-hosted AI-assisted development stack that runs in Docker inside WSL2. VS Code on any machine on your LAN can reach it.

| Layer | Component | Role |
|---|---|---|
| Orchestration and memory | **[Hermes Agent](https://github.com/NousResearch/hermes-agent)** (Nous Research) | Agent loop, tools (files, terminal, web), skills that improve with use, session history, ACP for editors |
| Long-term memory | **[Hindsight](https://github.com/vectorize-io/hindsight)** (Hermes memory provider) | Fact and entity extraction, semantic recall and reflection, stored in Postgres + pgvector |
| Routing and management | **[LiteLLM](https://github.com/BerriAI/litellm) proxy** | One OpenAI-compatible endpoint, model aliases, per-user virtual keys, rate limits, usage logs, optional cloud fallback |
| Local models | **llama.cpp server** (CUDA) | `coder`: Qwen3-Coder-30B-A3B (agent + chat). `autocomplete`: Qwen2.5-Coder-1.5B (FIM) |
| Persistence | **PostgreSQL 17 + pgvector** | LiteLLM (keys, spend, logs) and Hindsight (memories, embeddings) |

```mermaid
flowchart LR
  subgraph LAN["LAN clients"]
    VS["VS Code + Continue"]
    ACP["VS Code + ACP Client<br/>(on the WSL host)"]
  end
  subgraph WSL["WSL2 · Docker · network ai-stack"]
    LL["LiteLLM :4000"]
    HM["Hermes Agent :8642"]
    HS["Hindsight :8888"]
    C["llm-coder<br/>llama.cpp"]
    A["llm-autocomplete<br/>llama.cpp"]
    PG[("Postgres + pgvector")]
  end
  VS -- "coder / autocomplete / hermes-agent" --> LL
  ACP -- "docker exec hermes acp" --> HM
  LL -- "hermes-agent" --> HM
  HM -- "model: coder" --> LL
  LL --> C & A
  HM -- memory --> HS
  HS -- "model: memory" --> LL
  HS --> PG
  LL --> PG
```

**Design choices**

- **Everything that calls a model goes through LiteLLM.** That covers Hermes, Hindsight and the editors. You get one place to swap models, add a cloud fallback, set limits, and see who used what.
- **Hermes is also a "model" in LiteLLM** (`hermes-agent`). A LAN client needs one URL and one key, and can pick the raw model for speed or the agent for multi-step work.
- **Only two ports reach the LAN:** `4000` (LiteLLM) and `8642` (Hermes, optional). Postgres, the model servers and Hindsight stay internal or on `127.0.0.1`.
- **The workspace is mounted at the same path** inside Hermes, so paths in the agent's output match VS Code.

## Requirements

- Windows 11 + WSL2 (Ubuntu 24.04), Docker Engine in WSL **or** Docker Desktop
- NVIDIA GPU; **24 GB VRAM** for the defaults (other sizes: [docs/models.md](docs/models.md))
- 32 GB+ RAM, ~40 GB disk for images and models

Setting up Docker, GPU and LAN on WSL: **[docs/wsl-lan.md](docs/wsl-lan.md)**

## Quick start

```bash
git clone <this repo> ~/ai-stack && cd ~/ai-stack
scripts/bootstrap.sh          # secrets, config, start-up, virtual keys, memory plugin
docker compose logs -f llm-coder   # first start downloads ~20 GB of models
scripts/doctor.sh             # checks every hop, including a real inference
```

Then:

1. **LAN**: run `windows\setup-lan.ps1` as Administrator, then `wsl --shutdown` ([docs/wsl-lan.md](docs/wsl-lan.md#4-make-it-reachable-from-the-lan)).
2. **VS Code**: copy `vscode/continue-config.yaml` to `~/.continue/config.yaml` and fill in host and key ([docs/vscode.md](docs/vscode.md)).
3. **Hermes CLI** (optional): `docker exec -it hermes hermes` opens the full terminal UI.

## Endpoints

| URL | Who | Auth |
|---|---|---|
| `http://<host>:4000/v1` | LAN clients (OpenAI API) | LiteLLM virtual key |
| `http://localhost:4000/ui` | you (admin UI: keys, usage, logs) | `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` |
| `http://<host>:8642/v1` | direct Hermes API (model `hermes-agent`) | `HERMES_API_KEY` |
| `http://localhost:9999` | Hindsight UI (browse and fix memories) | — (local only) |
| `127.0.0.1:5432` | psql / DBeaver | `postgres` / `POSTGRES_PASSWORD` |

Models exposed by LiteLLM: `coder`, `autocomplete`, `memory` (used internally by Hindsight), `hermes-agent`.

## How memory works

Hermes keeps three layers, all on disk under `data/`:

1. **Session history and built-in memory**: Hermes' own SQLite `state.db`, plus memory and skill files in `data/hermes`. This holds conversations, full-text session search, and skills Hermes writes itself.
2. **Long-term semantic memory**: Hindsight, in Postgres (`hindsight` DB). After each turn Hermes retains facts and decisions. Before each turn it recalls the relevant ones. It also has `hindsight_recall` / `hindsight_reflect` tools. Memory bank: `dev` (`data/hermes/hindsight/config.json`).
3. **Usage and audit**: LiteLLM, in Postgres (`litellm` DB). This stores who called which model, latency and tokens. Prompt bodies are **not** stored by default (`store_prompts_in_spend_logs: false`).

## Day-to-day

```bash
docker compose ps                      # status
docker compose logs -f hermes          # follow a service
scripts/new-key.sh laptop-ana          # key for another machine/person
docker compose pull && docker compose up -d   # upgrade (pin digests in .env once stable)
```

**Swap the model:** edit `CODER_MODEL` / `CODER_CTX` in `.env`, then `docker compose up -d llm-coder`. If you change the context, update `max_input_tokens` in `litellm/config.yaml` and `model.context_length` in `data/hermes/config.yaml`.

**Cloud fallback:** uncomment `cloud-coder` and `fallbacks` in `litellm/config.yaml`, set the key in `.env`, then `docker compose up -d litellm`.

**Backup:**

```bash
docker exec ai-postgres pg_dumpall -U postgres | gzip > backup-$(date +%F).sql.gz
docker exec hermes hermes backup        # Hermes' own snapshot (never copy state.db by hand)
```

## Security notes

- **Hermes runs shell commands** inside its container, with your workspace mounted read-write. Anyone holding `HERMES_API_KEY`, or a LiteLLM key allowed to use `hermes-agent`, can act on that code. Treat those keys like SSH access to the repo.
- For a tighter setup, set `HERMES_BIND=127.0.0.1` in `.env`. LAN clients still reach Hermes through LiteLLM, with per-user keys that you can revoke.
- `LITELLM_MASTER_KEY` is the admin key. It stays on the server. Give clients virtual keys only.
- The firewall rules are limited to the **Private** profile and the **local subnet**. Never port-forward 4000 or 8642 on your router. For remote access, use Tailscale or WireGuard.
- `LITELLM_SALT_KEY` encrypts credentials stored in the DB. Changing it after the first run makes them unreadable.

## Layout

```
docker-compose.yml        all services
compose.cpu.yml           CPU-only override
.env.example              every setting (bootstrap.sh → .env)
litellm/config.yaml       model routes, fallbacks, logging
postgres/init/            first-boot DB/role/extension setup
hermes/                   Hermes config template + Hindsight plugin config
scripts/                  bootstrap, doctor, new-key
windows/                  .wslconfig + LAN firewall script (PowerShell)
vscode/                   Continue config, ACP settings
docs/                     WSL/LAN, models, VS Code guides
data/                     runtime state (git-ignored)
```
