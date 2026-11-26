# Contributing

## Commit messages: Conventional Commits

Every commit follows [Conventional Commits 1.0](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>(<scope>): <description>

<body: what and why, wrapped at 72>

<footers, e.g. BREAKING CHANGE: …, Co-Authored-By: …>
```

| Type | Use for |
|---|---|
| `feat` | a new capability (new service, script, profile, option) |
| `fix` | a bug fix |
| `docs` | documentation only |
| `refactor` | restructuring without behavior change |
| `perf` | performance (e.g. model or memory tuning) |
| `build` | images, dependencies, Compose build settings |
| `ci` | CI configuration |
| `test` | tests and checks |
| `chore` | maintenance that fits nowhere else |
| `style` | formatting only |
| `revert` | reverting a previous commit |

**Scopes** are the part of the stack touched: `compose`, `litellm`, `hermes`, `hindsight`, `postgres`, `llm`, `profiles`, `bootstrap`, `doctor`, `scripts`, `windows`, `vscode`, `docs`.

Rules:

- Subject in the imperative mood, lower case after the colon, no trailing period, ≤ 72 characters.
- A breaking change (renamed setting, changed port, removed profile) gets `!` after the type/scope and a `BREAKING CHANGE:` footer saying what to do.
- One logical change per commit.

Examples:

```
feat(scripts): add install-docker-wsl.sh for Ubuntu on WSL2
fix(bootstrap): refuse to run from the Windows drive
perf(llm): raise ubatch to 1024 for faster prompt processing
refactor(profiles)!: rename poc-wsl to gpu

BREAKING CHANGE: re-run `scripts/bootstrap.sh --profile gpu`.
```

### Enforce it locally

```bash
git config core.hooksPath .githooks
```

`.githooks/commit-msg` then rejects messages that don't match the format.

## Branches and pull requests

- `main` is the integration branch. **Every change reaches it through a pull request.** Nobody commits or pushes to `main` directly.
- Work on a topic branch named `<type>/<short-description>`, with the same types as commits, e.g. `feat/cloud-fallback`, `fix/crlf-checkout`, `docs/vscode-setup`.
- **Branch names never reference tools, assistants or vendors** (no `claude/…`, `copilot/…`, `ai/…`). They describe the change.
- Open the PR from that branch to `main` and fill in the template (`.github/pull_request_template.md`). The PR title is a Conventional Commit subject, since it becomes the squash-merge commit.
- Prefer **squash merge**, so `main` gets one conventional commit per PR. Delete the branch after merging.
