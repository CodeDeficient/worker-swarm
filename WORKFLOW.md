# Parallel AI Agent Workflow

> Orchestrate multiple AI coding agents in Docker containers to work on isolated git branches simultaneously, then merge results. This setup uses separate clones on separate branches instead of git worktrees for better isolation and simpler tooling. Turn 20 minutes of AI agent work into 4-8 hours of autonomous parallel output.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
  - [1. Dockerfile for the Agent](#1-dockerfile-for-the-agent)
  - [2. Docker Compose Configuration](#2-docker-compose-configuration)
  - [3. Worker Entrypoint Script](#3-worker-entrypoint-script)
  - [4. Clone Initialization Script](#4-clone-initialization-script)
- [Usage](#usage)
  - [Starting Workers](#starting-workers)
  - [Launching Tasks](#launching-tasks)
  - [Monitoring Progress](#monitoring-progress)
  - [Merging Results](#merging-results)
  - [Syncing Workers for Next Round](#syncing-workers-for-next-round)
- [Worker Prompt Engineering](#worker-prompt-engineering)
- [Batch Strategy](#batch-strategy)
- [Lessons Learned](#lessons-learned)
- [Safety & Best Practices](#safety--best-practices)
- [Troubleshooting](#troubleshooting)
- [Cost Considerations](#cost-considerations)
  - [Cost Calculator](#cost-calculator)
  - [Model Selection](#model-selection)
  - [Time Investment](#time-investment)
- [Full Automation Script (Optional)](#full-automation-script-optional)
- [File Structure](#file-structure)
- [Acknowledgments](#acknowledgments)
- [License](#license)
- [Contributing](#contributing)

---

## Overview

This workflow enables you to:

1. Run **N isolated AI agents** (e.g., 6) in separate Docker containers
2. Each agent gets its own **git clone on its own branch** (no file conflicts)
3. **Distribute work** across agents (e.g., 8-10 files per agent)
4. Agents work **autonomously and in parallel** — you can walk away
5. **Merge results** after each round and repeat

**Real results from a Next.js/TypeScript project:**

- 6 workers, each processing 8-10 files per 20-30 minute round
- ~40-50 new test files created per round
- Coverage went from 25% → 37%+ in the first day
- ~150+ commits from autonomous agent work

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│   Worker 1   │  │   Worker 2   │  │   Worker 3   │
│  Docker Ctr  │  │  Docker Ctr  │  │  Docker Ctr  │
│  Port 8081   │  │  Port 8082   │  │  Port 8083   │
│  Branch:     │  │  Branch:     │  │  Branch:     │
│  tests/w-1   │  │  tests/w-2   │  │  tests/w-3   │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                  │                  │
       ▼                  ▼                  ▼
┌──────────────────────────────────────────────────────────┐
│              Host Machine (Orchestrator)                   │
│                                                          │
│  git remote add wt-1 /home/user/projects/myproject-wt-1  │
│  git remote add wt-2 /home/user/projects/myproject-wt-2  │
│  git remote add wt-3 /home/user/projects/myproject-wt-3  │
│                                                          │
│  git fetch wt-1 tests/worker-1                           │
│  git merge wt-1/tests/worker-1                           │
└──────────────────────────────────────────────────────────┘
```

---

## Architecture

### Components

| Component             | Purpose                                                                                          |
| --------------------- | ------------------------------------------------------------------------------------------------ |
| **Host machine**      | Your dev machine. Runs the orchestrating agent (opencode/Claude/etc). Has the main git repo.     |
| **Worker containers** | N Docker containers, each running an AI agent server (e.g., `opencode serve`).                   |
| **Worker clones**     | Each container has its own git clone at a separate path on the host, mounted into the container. |
| **Git remotes**       | Worker clones are added as git remotes on the main repo for easy merging.                        |

### Key Design Decisions

1. **One git clone per worker** — Prevents file conflicts. Each worker operates on its own branch.
2. **Docker isolation** — Workers can't interfere with each other or the host. Network access for API calls still works.
3. **Mount-based clones** — Worker clones live on the host filesystem and are bind-mounted into containers. This makes merging from the host trivial.
4. **REST API communication** — The host talks to workers via HTTP (opencode's `--attach` flag connects to the worker's server).

### Why Branches Instead of Git Worktrees?

Git supports two approaches for parallel development on the same repo: **worktrees** (multiple checkouts of the same repo) and **separate clones on separate branches** (our approach). We chose separate clones for practical reasons:

- **No tool pollution** — Worktrees live inside or alongside your project directory. If your linter, type checker, or test runner scans the entire project root, it picks up every worktree simultaneously. We saw our error count triple with just two agents because `eslint` and `tsc` processed the same codebase three times.
- **Simpler mental model** — Each clone is a completely isolated folder. No need to configure `.gitignore`, `tsconfig.json` exclude paths, or `eslint` ignore patterns for sibling worktrees.
- **Independent review** — With separate clones, you can run `/review` or CI commands on any worker's branch without worrying about cross-contamination from other worktrees.
- **Cleaner cleanup** — Removing a clone is just `rm -rf`. Worktree removal requires `git worktree prune` and can leave dangling references.

The tradeoff is disk space — each clone is a full copy of the repo. But for most projects, that's a worthwhile cost for the simplicity.

### Data Flow

```
Host                          Worker Container
─────                         ─────────────────
                              Container runs:
opencode run                    opencode serve
  --attach http://host:808N     (listens on port 8080)
  -m model-name                (mapped to host port 808N)
  "prompt"
       │
       ▼  HTTP request
  ┌─────────────┐  ──────────►  ┌─────────────────┐
  │ opencode CLI │               │ opencode server  │
  │ (client)     │               │ reads/writes     │
  └─────────────┘  ◄──────────  │ /app (mount)     │
       │            response     └─────────────────┘
       ▼
  Log to /tmp/wN.log
```

---

## Prerequisites

- **Docker** and **Docker Compose**
- **OpenCode CLI** (or similar agent that supports `serve` and `--attach` modes)
- An **AI model API key** (we used MiniMax-M2.7 via MiniMax.io)
- A **git repository** you want to work on
- **Enough disk space** for N git clones (each ~full repo size)

---

## Setup

### 1. Dockerfile for the Agent

Create a Dockerfile that installs your AI agent CLI and sets up the runtime environment:

```dockerfile
# Dockerfile.opencode
FROM node:20-bookworm

# Install opencode CLI
RUN npm install -g @anthropic-ai/opencode@latest

# Create non-root user
RUN useradd -m -s /bin/bash node
USER node

# Set up config and data directories
RUN mkdir -p /home/node/.config/opencode \
    && mkdir -p /home/node/.local/share/opencode

# Set working directory
WORKDIR /app

# Expose the agent server port
EXPOSE 8080

# Start the agent in server mode
CMD ["opencode", "serve", "--port", "8080"]
```

### 2. Docker Compose Configuration

Define one service per worker. The critical parts:

- **Ports**: Each worker gets a unique host port (8081-8086)
- **Volumes**: Each worker gets its own git clone bind-mounted as `/app`
- **Environment**: API keys and permission config
- **Health check**: Ensure the agent server is ready before sending tasks

```yaml
# docker-compose.opencode.yml
services:
  wt-1:
    build:
      context: .
      dockerfile: Dockerfile.opencode
    container_name: myproject-agent-wt-1
    ports:
      - '8081:8080'
    volumes:
      - /home/user/projects/myproject-wt-1:/app
      - /home/user/.config/opencode/skills:/home/node/.config/opencode/skills:ro
    environment:
      - MINIMAX_API_KEY=${MINIMAX_API_KEY}
      - OPENCODE_CONFIG_CONTENT={"permission":{"read":{"*":"allow"},"write":{"*":"allow"},"bash":{"*":"allow"},"edit":{"*":"allow"}},"external_directory":{"*":"allow"}}
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:8080/health']
      interval: 10s
      timeout: 5s
      retries: 30
    restart: unless-stopped

  wt-2:
    # ... same pattern, port 8082, mount wt-2 clone

  # Repeat for wt-3 through wt-N
```

**Important**: `OPENCODE_CONFIG_CONTENT` is the highest-priority config source and ensures workers have write permissions. Without it, workers may reject file edits because the bind-mounted directory appears as an "external directory" from the server's perspective.

### 3. Worker Entrypoint Script

If you want workers to auto-initialize their git state on startup:

```bash
#!/bin/bash
# docker/worker-entrypoint.sh

# Wait for the main repo to be available
MAIN_REPO="/host/repo/path"
WORKER_BRANCH="tests/worker-${WORKER_NUM}"

cd /app

# Initialize from main repo if empty
if [ ! -d ".git" ]; then
  git clone "$MAIN_REPO" .
fi

# Ensure we're on the right branch
git fetch origin
git checkout -B "$WORKER_BRANCH" origin/main 2>/dev/null || git checkout -B "$WORKER_BRANCH"

# Install dependencies if needed
if [ ! -d "node_modules" ]; then
  npm ci --ignore-scripts 2>/dev/null || npm install --ignore-scripts
fi

# Start the agent server
exec opencode serve --port 8080
```

### 4. Clone Initialization Script

Run this once on the host to create the worker clones and git remotes:

```bash
#!/bin/bash
# scripts/init-worker-clones.sh

MAIN_REPO="/home/user/projects/myproject"
NUM_WORKERS=6

for i in $(seq 1 $NUM_WORKERS); do
  CLONE_DIR="${MAIN_REPO}-wt-${i}"

  # Create clone if it doesn't exist
  if [ ! -d "$CLONE_DIR" ]; then
    echo "Creating clone for worker $i..."
    git clone "$MAIN_REPO" "$CLONE_DIR"
    cd "$CLONE_DIR"
    git checkout -B "tests/worker-${i}"
  fi

  # Add as remote on main repo
  cd "$MAIN_REPO"
  if ! git remote | grep -q "wt-${i}"; then
    git remote add "wt-${i}" "$CLONE_DIR"
    echo "Added remote wt-${i}"
  fi
done

echo "All $NUM_WORKERS worker clones ready."
```

---

## Usage

### Starting Workers

```bash
# Start all worker containers
docker compose -f docker-compose.opencode.yml up -d

# Wait for health checks
docker ps --format "table {{.Names}}\t{{.Status}}" | grep opencode
```

### Launching Tasks

Send a task to each worker via the `opencode run --attach` command:

```bash
export OPENCODE_PERMISSION='{"permission":{"read":{"*":"allow"},"write":{"*":"allow"},"bash":{"*":"allow"},"edit":{"*":"allow"}}}'

# Launch all 6 workers in parallel (background)
for i in 1 2 3 4 5 6; do
  PORT=$((8080 + i))
  opencode run \
    --attach "http://localhost:${PORT}" \
    -m "your-model-name" \
    --format json \
    --title "Worker ${i}: Write tests" \
    "Your detailed prompt here..." \
    > "/tmp/w${i}.log" 2>&1 &
done
```

### Monitoring Progress

```bash
# Quick status check
for i in 1 2 3 4 5 6; do
  cd "/home/user/projects/myproject-wt-${i}"
  commits=$(git log --oneline BASE_SHA..HEAD | wc -l)
  modified=$(git diff --name-only | wc -l)
  echo "W${i}: ${commits} commits, ${modified} uncommitted"
done

# Check if workers are still running
ps aux | grep "opencode run" | grep -v grep

# Tail a specific worker's log
tail -f /tmp/w3.log
```

### Merging Results

```bash
# Commit any uncommitted work in worker clones first
for i in 1 2 3 4 5 6; do
  cd "/home/user/projects/myproject-wt-${i}"
  if [ -n "$(git status --porcelain)" ]; then
    git add -A && git commit -m "test: worker ${i} remaining changes"
  fi
done

# Merge all worker branches into main
cd /home/user/projects/myproject
for i in 1 2 3 4 5 6; do
  git fetch "wt-${i}" "tests/worker-${i}"
  git merge "wt-${i}/tests/worker-${i}" -m "Merge wt-${i} batch N" --no-edit
done
```

### Syncing Workers for Next Round

After merging, reset all worker clones to the latest HEAD:

```bash
for i in 1 2 3 4 5 6; do
  cd "/home/user/projects/myproject-wt-${i}"
  git fetch /home/user/projects/myproject HEAD
  git reset --hard FETCH_HEAD
  git checkout -B "tests/worker-${i}"
done
```

---

## Worker Prompt Engineering

The prompt you send to each worker is the most critical part. Here's what we learned:

### Structure of a Good Worker Prompt

```
1. Role definition ("You are Worker 3")
2. Task description ("Write NEW test files for source files with 0% coverage")
3. Hard rules (ESM mocking pattern, no npm installs, commit after each file)
4. File list with exact paths (source -> test mapping)
5. Step-by-step instructions for each file
6. "START NOW" to prevent preamble
```

### Example Prompt Template

```
You are Worker {N}. Your job is to {TASK_DESCRIPTION}.

CRITICAL RULES:
1. Use jest.unstable_mockModule() for ALL mocks, NEVER jest.mock()
2. ESM pattern: jest.unstable_mockModule BEFORE dynamic import, reset in beforeEach
3. Target 90%+ coverage per file
4. NEVER install npm packages
5. NEVER use 'any' type
6. Commit after EACH test file: git add -A && git commit -m 'test: add coverage for X'
7. If a source file is too complex to mock, test the pure helpers and skip the rest
8. Work through ALL files. Do NOT stop early.

YOUR {N} FILES:
1. lib/utils/helpers.ts -> __tests__/lib/utils/helpers.test.ts
2. lib/services/database.ts -> __tests__/lib/services/database.test.ts
...

For each file:
1. Read the source file to understand exports and logic
2. Write a comprehensive test file
3. Run: npx jest path/to/test.test.ts --no-coverage to verify
4. Fix any failures
5. git add -A && git commit

START NOW with file 1.
```

### Key Prompting Tips

| Tip                               | Why                                                                                |
| --------------------------------- | ---------------------------------------------------------------------------------- |
| **"Commit after EACH file"**      | Workers frequently forget to commit. Remind them repeatedly.                       |
| **"NEVER stop early"**            | Without this, workers stop after 2-3 files and declare victory.                    |
| **"NEVER install npm packages"**  | Workers will try to `npm install` solutions instead of using what's available.     |
| **Specify exact test file paths** | Prevents workers from putting tests in wrong directories.                          |
| **"If too complex, skip"**        | Prevents workers from getting stuck on one impossible file for the entire session. |
| **"START NOW"**                   | Prevents 2-3 turns of preamble about how they'll approach the task.                |

---

## Batch Strategy

### Round-Based Approach

The most effective pattern is **rounds** of 20-30 minutes each:

```
Round 1: Launch 6 workers × 8-10 files = 48-60 files
         ↓ Wait 30 min
         Merge results
         ↓
Round 2: Sync workers, launch next 48-60 files
         ↓ Wait 30 min
         Merge results
         ↓
... repeat until done
```

### File Distribution

Distribute files strategically:

| Worker | File Type         | Reasoning                |
| ------ | ----------------- | ------------------------ |
| W1, W2 | API handlers      | Similar mocking patterns |
| W3, W4 | Supabase services | Same DB mock chain       |
| W5     | Pure utilities    | Fastest turnaround       |
| W6     | Mixed/config      | Catch-all                |

### Coverage-Driven Selection

Use coverage reports to prioritize:

```bash
# Generate JSON coverage
npx jest --coverage --coverageReporters=json --silent

# Find 0% files sorted by size (most impactful first)
node -e "
const cov = require('./coverage/coverage-final.json');
const results = [];
for (const [path, data] of Object.entries(cov)) {
  if (path.includes('__tests__') || path.includes('node_modules')) continue;
  const stmts = data.s;
  const total = Object.keys(stmts).length;
  const covered = Object.values(stmts).filter(v => v > 0).length;
  if (total > 0 && covered === 0) results.push({path, total});
}
results.sort((a,b) => b.total - a.total);
results.forEach(r => console.log(r.total, r.path));
"
```

### What to Skip

Not everything is worth testing with AI agents:

| Skip                         | Why                                                         |
| ---------------------------- | ----------------------------------------------------------- |
| **React components**         | Require complex render setup, mocking is fragile            |
| **API routes (Next.js)**     | ESM + SSR mocking is broken in Jest; use Playwright instead |
| **Type definition files**    | No executable code                                          |
| **Generated files**          | Will be overwritten                                         |
| **Config with side effects** | Module-level initialization is hard to mock                 |

---

## Lessons Learned

### What Works Well

1. **Pure utility functions** — Agents excel at testing pure functions with no dependencies. Coverage goes to 100% fast.
2. **Service layers** — Good mocking patterns exist for Supabase/service layers. Agents handle these well.
3. **Small files (20-80 lines)** — Agents process these in 2-3 minutes each.
4. **Multiple rounds** — Each round teaches the agents what works. Later rounds are faster.
5. **Simple retry for stuck workers** — If a worker finishes 0 commits, just relaunch it with simpler files.

### What Struggles

1. **ESM module mocking** — `jest.unstable_mockModule()` is fragile. Some import patterns simply can't be mocked. Accept ~80% instead of fighting for 90%.
2. **Module-level side effects** — Code that runs at import time (e.g., `const client = createClient()`) is nearly impossible to mock.
3. **Workers that don't commit** — ~50% of the time, workers edit files but forget to `git commit`. Always check and manually commit uncommitted changes after a round.
4. **Workers that quit early** — Without explicit "do NOT stop early" instructions, workers will do 2-3 files and stop.
5. **Worker consistency** — Same model, same prompt, wildly different results. W4 might do 8/8 files perfectly while W2 does 0/8. Relaunch with simpler tasks.

### The 50% Rule

Expect that roughly half of what agents produce will need manual review:

- ~50% of test files are correct and comprehensive
- ~30% compile but have weak assertions (testing mocks, not behavior)
- ~20% have syntax errors or broken imports

This is still dramatically faster than writing tests manually.

### Orchestrator Pattern

The most effective pattern we found:

```
Human → Orchestrator Agent → 6 Worker Agents
                ↑                    ↓
           monitors logs         git commits
           merges results        on isolated branches
           pushes to GitHub
           relaunches stuck workers
```

The orchestrator agent (you, or an AI agent like opencode) handles:

- Distributing files across workers
- Launching workers with appropriate prompts
- Monitoring progress
- Merging results
- Identifying the next batch
- Relaunching workers that get stuck

### Orchestrator Model

The orchestrator (which distributes tasks and monitors workers) uses a different model than the workers themselves:

| Model | Provider | When | Notes |
|-------|----------|------|-------|
| **GLM-5.1** | Z.ai (z.ai) | Default | Primary orchestrator model |
| **GLM-5-Turbo** | Z.ai (z.ai) | Non-peak hours | Falls back during off-peak; both models sip on usage either way thanks to long timeout tolerance |

### Orchestrator Heartbeat & Merge Cycle

The orchestrator runs a repeatable cycle each round:

#### 1. Heartbeat Check (every 5-10 minutes)

```bash
# Check if each worker is still producing commits
for i in 1 2 3 4 5 6; do
  cd "/home/user/projects/myproject-wt-${i}"
  recent=$(git log --oneline --since="10 minutes ago" | wc -l)
  echo "W${i}: ${recent} commits in last 10 min"
done
```

If a worker shows **zero activity for 15+ minutes**, it's likely stuck. Check its log:

```bash
tail -100 /tmp/w3.log
```

Common reasons: worker hit a complex file, ran out of tokens, or got confused by mocking. **Relaunch it with simpler files** — don't try to debug the stuck worker.

#### 2. Local Merge (after each round)

Before merging worker branches into the main branch:

```bash
# First, force-commit any dangling changes
for i in 1 2 3 4 5 6; do
  cd "/home/user/projects/myproject-wt-${i}"
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "test: worker ${i} uncommitted changes from round ${round}"
  fi
done
```

Then merge on a dedicated branch (never directly into main):

```bash
cd /home/user/projects/myproject
git checkout -b "test/merge-round-${round}" main

for i in 1 2 3 4 5 6; do
  git fetch "wt-${i}" "tests/worker-${i}"
  git merge "wt-${i}/tests/worker-${i}" -m "Merge round ${round} worker ${i}" --no-edit || {
    echo "Conflict on worker ${i}, accepting theirs for test files"
    git checkout --theirs -- .
    git add -A
    git commit -m "Merge round ${round} worker ${i} (resolved conflicts)" --no-edit
  }
done
```

#### 3. Verification

```bash
# Run the test suite to verify nothing broke
npm test -- --silent

# Check coverage improved
npx jest --coverage --coverageReporters=text --silent | grep "All files"
```

#### 4. Push and Sync

```bash
# Push the merge branch for review
git push origin "test/merge-round-${round}"

# Reset all workers to latest HEAD for next round
for i in 1 2 3 4 5 6; do
  cd "/home/user/projects/myproject-wt-${i}"
  git fetch /home/user/projects/myproject HEAD
  git reset --hard FETCH_HEAD
  git checkout -B "tests/worker-${i}"
done
```

---

## Safety & Best Practices

### Security

- **Never commit API keys** — use `.env` files and ensure they're in `.gitignore`
- **Isolate worker containers** — workers run as non-root users; don't grant `--privileged`
- **Don't mount sensitive host directories** — only mount the worker clone and OpenCode config
- **Rotate API keys** if you ever accidentally expose them in logs or commit history

### Git Safety

- **Always create a backup branch** before merging: `git checkout -b backup/before-round-N`
- **Never merge directly into main** — always use an intermediate merge branch
- **Review merge branches via PR** before integrating into your primary branch
- **Use `--no-verify` cautiously** — skipping pre-commit hooks during merge can hide issues

### Worker Reliability

- **Launch workers sequentially with 5-10 second gaps** — prevents API rate limit spikes
- **Set a round timeout** — 45 minutes max per round; kill stuck workers and relaunch
- **Always commit dangling changes** before merging — workers often edit files without committing
- **Monitor disk space** — N clones can consume significant storage (each ~full repo size)

### Quality Control

- **Always run the test suite after merging** — verify the merge didn't break anything
- **Check coverage improved** — if coverage went down, something went wrong in the merge
- **Spot-check agent output** — review a sample of 3-5 files per worker per round
- **Track error rate** — if >40% of worker output needs fixing, reconsider the prompt or model

### Cost Control

- **Use cheaper models for workers** — save expensive models for orchestrating
- **Limit concurrent rounds** — don't run multiple round cycles simultaneously
- **Set API budget alerts** — most providers support spending caps or alerting
- **Dry-run file distribution** — verify your file list before launching expensive workers

---

## Troubleshooting

### Workers Can't Write Files

**Symptom**: Worker reads files but all edits are rejected.

**Cause**: Permission configuration missing. The container's working directory (`/app`) is a bind mount that appears as an "external directory" to the opencode server.

**Fix**: Add `OPENCODE_CONFIG_CONTENT` env var to docker-compose:

```yaml
environment:
  - OPENCODE_CONFIG_CONTENT={"permission":{"read":{"*":"allow"},"write":{"*":"allow"},"bash":{"*":"allow"},"edit":{"*":"allow"}},"external_directory":{"*":"allow"}}
```

### Workers Finish Immediately With 0 Commits

**Symptom**: Worker process exits after 1-2 minutes with no edits.

**Cause**: The task was too complex for the model, or the files had deep dependency chains the worker couldn't resolve.

**Fix**: Relaunch with simpler files (pure utilities, small files). Or split the task into smaller pieces.

### Git Merge Conflicts

**Symptom**: `git merge` fails with conflicts on test files.

**Fix**: For test files, just accept theirs:

```bash
git checkout --theirs path/to/conflicting.test.ts
git add path/to/conflicting.test.ts
git commit --no-edit
```

### Worker Containers Not Starting

**Symptom**: `docker compose up` shows containers exiting immediately.

**Fix**: Check that worker clone directories exist:

```bash
ls -la /home/user/projects/myproject-wt-1/
# Should show .git, package.json, etc.
```

### Model Rate Limits

**Symptom**: Workers slow down or error out mid-task.

**Fix**: Use a model with high rate limits. We found MiniMax-M2.7 via MiniMax.io had generous limits. Consider staggering worker launches by 30 seconds.

---

## Cost Considerations

### Token Usage Per Round

With 6 workers processing 8-10 files each over 20-30 minutes:

| Metric                      | Estimated Cost                  |
| --------------------------- | ------------------------------- |
| Input tokens per worker     | ~200-500K tokens                |
| Output tokens per worker    | ~50-150K tokens                 |
| Total per round (6 workers) | ~1.5-4M input + 300-900K output |
| API cost per round          | ~$0.50-3.00 (model dependent)   |
| **Cost per test file**      | **~$0.03-0.10**                 |

### Cost Calculator

**Per-round estimate (6 workers, 8-10 files each):**

| Metric | Low End | Typical | High End |
|--------|---------|---------|----------|
| Input tokens per worker | 150K | 300K | 500K |
| Output tokens per worker | 30K | 80K | 150K |
| **Total input (6 workers)** | 900K | 1.8M | 3.0M |
| **Total output (6 workers)** | 180K | 480K | 900K |
| Orchestrator overhead | 50K | 100K | 200K |
| **Grand total per round** | ~1.1M tokens | ~2.4M tokens | ~4.1M tokens |

**Cost per round by model:**

| Model | Input ($/1M) | Output ($/1M) | Est. Cost/Round |
|-------|-------------|--------------|-----------------|
| MiniMax-M2.7 | $0.30 | $0.60 | $0.50-1.50 |
| Gemini Flash | $0.10 | $0.40 | $0.20-0.80 |
| GPT-4o-mini | $0.15 | $0.60 | $0.30-1.00 |
| Claude Haiku | $0.25 | $1.25 | $0.50-2.00 |
| GPT-4o | $2.50 | $10.00 | $5.00-15.00 |
| Claude Sonnet | $3.00 | $15.00 | $7.00-25.00 |

**Monthly projection (daily runs, ~30 rounds/month):**

| Setup | Workers | Rounds/Day | Est. Monthly Cost |
|-------|---------|------------|-------------------|
| Budget (MiniMax) | 6 | 3 | $15-45 |
| Balanced (Mixed) | 6 | 3 | $25-75 |
| Quality (Claude) | 6 | 3 | $200-750 |

### Model Selection

| Model           | Provider      | Speed     | Quality   | Cost     | Notes                     |
|-----------------|---------------|-----------|-----------|----------|---------------------------|
| GLM-5.1         | Z.ai          | Fast      | Excellent | Low      | Orchestrator (default)    |
| GLM-5-Turbo     | Z.ai          | Very fast | Good      | Low      | Orchestrator (non-peak)   |
| MiniMax-M2.7    | MiniMax.io    | Fast      | Good      | Low      | Best for parallel work    |
| GPT-4o          | OpenAI        | Medium    | Excellent | High     | Use for complex tasks     |
| Claude Sonnet   | Anthropic     | Medium    | Excellent | High     | Use for complex tasks     |
| Gemini Flash    | Google        | Very fast | Good      | Very low | Good for simple utilities |

### Time Investment

| Activity                  | Time                                               |
| ------------------------- | -------------------------------------------------- |
| Initial setup (one-time)  | 2-3 hours                                          |
| Per-round orchestration   | 5-10 minutes                                       |
| Per-round autonomous work | 20-30 minutes                                      |
| Post-round merge + review | 5-10 minutes                                       |
| **Total per round**       | **~35-50 minutes** (only 10-20 min of active work) |

---

## Full Automation Script (Optional)

For true "set it and forget it" operation, you can script the entire loop:

```bash
#!/bin/bash
# scripts/auto-test-rounds.sh
# Runs N rounds of parallel test generation autonomously

NUM_WORKERS=6
NUM_ROUNDS=4
MAIN_REPO="/home/user/projects/myproject"
BASE_BRANCH="main"
MODEL="minimax-coding-plan/MiniMax-M2.7"

for round in $(seq 1 $NUM_ROUNDS); do
  echo "=== Round $round of $NUM_ROUNDS ==="

  # 1. Generate file list from coverage report
  echo "Generating coverage report..."
  cd "$MAIN_REPO"
  npx jest --coverage --coverageReporters=json --silent

  # 2. Parse coverage to find low-coverage files
  # (Use a Node script to output file assignments to /tmp/worker-N-files.txt)
  node scripts/assign-files-to-workers.js $NUM_WORKERS

  # 3. Sync workers to latest
  for i in $(seq 1 $NUM_WORKERS); do
    cd "${MAIN_REPO}-wt-${i}"
    git fetch "$MAIN_REPO" HEAD
    git reset --hard FETCH_HEAD
    git checkout -B "tests/worker-${i}"
  done

  # 4. Launch workers
  cd "$MAIN_REPO"
  for i in $(seq 1 $NUM_WORKERS); do
    PORT=$((8080 + i))
    FILES=$(cat "/tmp/worker-${i}-files.txt")
    opencode run \
      --attach "http://localhost:${PORT}" \
      -m "$MODEL" \
      --format json \
      --title "Round ${round} Worker ${i}" \
      "Write tests for these files: $FILES. [standard prompt template]" \
      > "/tmp/w${i}.log" 2>&1 &
  done

  # 5. Wait for workers to finish (with timeout)
  echo "Waiting for workers (max 45 minutes)..."
  sleep 2700  # 45 minutes

  # 6. Commit any uncommitted changes
  for i in $(seq 1 $NUM_WORKERS); do
    cd "${MAIN_REPO}-wt-${i}"
    if [ -n "$(git status --porcelain)" ]; then
      git add -A && git commit -m "test: round $round worker $i remaining"
    fi
  done

  # 7. Merge all worker branches
  cd "$MAIN_REPO"
  git checkout -b "test/round-${round}" "$BASE_BRANCH"
  for i in $(seq 1 $NUM_WORKERS); do
    git fetch "wt-${i}" "tests/worker-${i}"
    git merge "wt-${i}/tests/worker-${i}" -m "Merge round $round wt-${i}" --no-edit
  done

  # 8. Run tests to verify
  npm test -- --silent 2>&1 | tail -5

  # 9. Push
  git push origin "test/round-${round}"

  echo "=== Round $round complete ==="
done

echo "=== All $NUM_ROUNDS rounds complete ==="
```

---

## File Structure

Here's the complete file structure for this workflow:

```
myproject/
├── docker-compose.opencode.yml    # Worker container definitions
├── Dockerfile.opencode            # Agent container image
├── docker/
│   └── worker-entrypoint.sh       # Container startup script
├── scripts/
│   ├── init-worker-clones.sh      # One-time clone setup
│   ├── cleanup-worker-clones.sh   # Remove clones
│   └── assign-files-to-workers.js # Coverage-based file distribution
├── docs/
│   └── WORKFLOW.md                  # This document
│
├── myproject-wt-1/                # Worker 1 clone (git remote: wt-1)
├── myproject-wt-2/                # Worker 2 clone (git remote: wt-2)
├── myproject-wt-3/                # Worker 3 clone (git remote: wt-3)
├── myproject-wt-4/                # Worker 4 clone (git remote: wt-4)
├── myproject-wt-5/                # Worker 5 clone (git remote: wt-5)
└── myproject-wt-6/                # Worker 6 clone (git remote: wt-6)
```

---

## Acknowledgments

This workflow was developed while working on a large Next.js/TypeScript codebase. The approach emerged from the need to dramatically increase test coverage (from 25% to 90%+) in a production project.

Key tools that make this possible:

- [OpenCode](https://opencode.ai) — AI coding agent with `serve`/`attach` mode
- [Docker](https://docker.com) — Container isolation
- [Jest](https://jestjs.io) — Test framework (though any framework works)
- [GLM-5.1 / GLM-5-Turbo](https://z.ai) — Orchestrator models via Z.ai
- [MiniMax-M2.7](https://minimax.io) — Fast, affordable model for parallel work

---

## License

This workflow documentation is released under the **MIT License**.

You are free to:
- Use this workflow in personal and commercial projects
- Modify and adapt the scripts for your own needs
- Share and distribute the documentation

You do not need to:
- Attribute the author (though it's appreciated)
- Open-source your modifications

```
MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Contributing

Contributions are welcome! Here's how you can help improve this workflow:

- **Share your results** — What model, worker count, and round size worked best for your project?
- **Report issues** — If a section doesn't match your experience, let us know
- **Suggest improvements** — Better prompts, automation scripts, or merge strategies
- **Fix errors** — Typos, broken commands, or outdated references

### How to Contribute

1. Fork the repository
2. Create a branch (`git checkout -b docs/improve-cost-table`)
3. Make your changes
4. Submit a pull request

### What We're Looking For

- Real-world cost benchmarks from different providers
- Alternative orchestrator patterns (GitHub Actions, CI pipelines, etc.)
- Prompt templates for different task types (refactoring, documentation, bug fixes)
- Platform-specific adapters (Windows, macOS, cloud VMs)
