# Worker Swarm

> Orchestrate multiple AI coding agents in Docker containers to work on isolated git branches simultaneously, then merge results. Turn 20 minutes of AI agent work into 4-8 hours of autonomous parallel output.

## At a Glance

Run **N AI agents** in parallel, each in its own Docker container with its own git clone and branch. The orchestrator distributes tasks, monitors progress, and merges results after each round.

```mermaid
flowchart TD
    subgraph Host["🖥️ Host Machine (Orchestrator)"]
        O["Orchestrator Agent"]
        subgraph Workers["Worker Containers"]
            W1["Worker 1\nPort 8081\nBranch: tests/worker-1"]
            W2["Worker 2\nPort 8082\nBranch: tests/worker-2"]
            W3["Worker 3\nPort 8083\nBranch: tests/worker-3"]
        end
    end

    O -->|"HTTP attach + prompt"| W1
    O -->|"HTTP attach + prompt"| W2
    O -->|"HTTP attach + prompt"| W3

    subgraph Filesystem["Host Filesystem"]
        C1["myproject-wt-1/"]
        C2["myproject-wt-2/"]
        C3["myproject-wt-3/"]
    end

    W1 -. mount .-> C1
    W2 -. mount .-> C2
    W3 -. mount .-> C3

    C1 -->|"git fetch + merge"| M["Main Repo"]
    C2 -->|"git fetch + merge"| M
    C3 -->|"git fetch + merge"| M

    style Host fill:#1a1a2e,stroke:#e94560,color:#fff
    style Filesystem fill:#16213e,stroke:#0f3460,color:#fff
    style O fill:#e94560,color:#fff
    style W1 fill:#0f3460,color:#fff
    style W2 fill:#0f3460,color:#fff
    style W3 fill:#0f3460,color:#fff
    style M fill:#533483,color:#fff
```

## How It Works

1. **Init** — Create N isolated git clones, each on its own branch
2. **Launch** — Start Docker containers, one per worker, with bind-mounted clones
3. **Distribute** — Send each worker a unique task (e.g., 8-10 files each)
4. **Work** — Agents edit, test, and commit autonomously in parallel
5. **Merge** — Fetch worker branches, merge results, verify, repeat

```mermaid
sequenceDiagram
    participant H as 👤 Orchestrator
    participant D as 🐳 Docker Compose
    participant W as 🤖 Workers (×N)
    participant G as 📦 Main Repo

    H->>D: docker compose up -d
    D-->>H: Workers healthy

    loop Each Round
        H->>W: Launch tasks (HTTP attach + prompt)
        W-->>W: Work autonomously (20-30 min)
        H->>H: Heartbeat check (every 5-10 min)
        W-->>H: git commits accumulate

        H->>H: Commit dangling changes
        H->>G: Merge merge branch
        H->>G: Run tests + verify coverage
        H->>G: Push merge branch for review
        H->>W: Sync to latest HEAD
    end
```

## Why Branches Instead of Worktrees?

We use **separate clones on separate branches** instead of `git worktree` because:

- **No tool pollution** — `eslint` and `tsc` won't scan N copies of the same codebase (we saw our error count triple with worktrees)
- **Simpler mental model** — each clone is an isolated folder, no `tsconfig.json` or `eslint` exclude config needed
- **Independent review** — run `/review` on any worker branch without cross-contamination
- **Cleaner cleanup** — `rm -rf` vs `git worktree prune`

The tradeoff is disk space — each clone is a full copy of the repo.

## Quick Start

```bash
# 1. Create worker clones
./scripts/init-worker-clones.sh

# 2. Start containers
docker compose -f docker-compose.opencode.yml up -d

# 3. Launch workers (example)
for i in 1 2 3 4 5 6; do
  PORT=$((8080 + i))
  opencode run --attach "http://localhost:${PORT}" \
    -m "your-model" \
    "Your task prompt here..." \
    > "/tmp/w${i}.log" 2>&1 &
done

# 4. Monitor progress
for i in 1 2 3 4 5 6; do
  cd "myproject-wt-${i}"
  echo "W${i}: $(git log --oneline --since='10 minutes ago' | wc -l) commits"
done

# 5. Merge results
for i in 1 2 3 4 5 6; do
  git fetch "wt-${i}" "tests/worker-${i}"
  git merge "wt-${i}/tests/worker-${i}" --no-edit
done
```

## File Structure

```
myproject/
├── docker-compose.opencode.yml    # Worker container definitions
├── Dockerfile.opencode            # Agent container image
├── docker/
│   └── worker-entrypoint.sh       # Container startup script
├── scripts/
│   ├── init-worker-clones.sh      # One-time clone setup
│   └── cleanup-worker-clones.sh   # Remove clones
├── docs/
│   └── WORKFLOW.md                # Full workflow guide ← deep dive
│
├── myproject-wt-1/                # Worker 1 clone (git remote: wt-1)
├── myproject-wt-2/                # Worker 2 clone (git remote: wt-2)
└── myproject-wt-N/                # Worker N clone (git remote: wt-N)
```

## Model Stack

| Role | Model | Provider | Notes |
|------|-------|----------|-------|
| **Orchestrator** | GLM-5.1 / GLM-5-Turbo | Z.ai | Primary / non-peak fallback |
| **Workers** | MiniMax-M2.7 | MiniMax.io | Fast, affordable for parallel work |

## Cost Estimate

With 6 workers processing 8-10 files per round:

| Metric | Value |
|--------|-------|
| Tokens per round | ~1.1M–4.1M total |
| Cost per round | $0.20–$3.00 (model dependent) |
| Cost per test file | ~$0.03–$0.10 |
| Monthly (30 rounds) | $15–$75 (budget setup) |

## Full Documentation

The **[WORKFLOW.md](WORKFLOW.md)** guide covers:
- Detailed setup (Dockerfile, compose, entrypoints)
- Worker prompt engineering with examples
- Batch strategy and coverage-driven file selection
- Orchestrator heartbeat & merge cycle
- Safety & best practices
- Troubleshooting
- Detailed cost calculator
- Full automation script

## License

MIT. See [WORKFLOW.md](WORKFLOW.md#license) for full text.

## Contributing

Contributions welcome — better prompts, cost benchmarks, alternative orchestrator patterns, platform adapters. See [WORKFLOW.md](WORKFLOW.md#contributing) for details.
