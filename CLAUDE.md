# Instructions for AI coding assistants

Follow [CONTRIBUTING.md](CONTRIBUTING.md). In particular:

- **Commits:** Conventional Commits only (`<type>(<scope>): <description>`, subject ≤ 72 chars, imperative). Breaking changes use `!` plus a `BREAKING CHANGE:` footer.
- **Branches:** never create a branch whose name references Claude or any other assistant (no `claude/…`). Use `<type>/<short-description>` (e.g. `fix/crlf-checkout`), or commit to `main` when the maintainer asks.
- The stack targets one machine: a WSL2 laptop (16 CPU / 32 GB / Blackwell 8 GB), reachable only from the home LAN. Don't add VPS, Tailscale or public-exposure configuration.
- Keep `docker-compose.gpu.yml` and `docker-compose.cpu.yml` identical for the shared services (`scripts/check-compose.sh`).
- Scripts must keep LF line endings and need only bash + docker on the host.
