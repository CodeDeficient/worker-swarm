#!/bin/bash
# docker/worker-entrypoint.sh
# Initializes git state in the worker container, then starts the agent server.
#
# Usage: Set as CMD or ENTRYPOINT in docker-compose.yml.
# Expected env vars:
#   MAIN_REPO       — path to the main repository on the host (mounted read-only)
#   WORKER_BRANCH   — branch name for this worker (e.g., tests/worker-1)

set -euo pipefail

MAIN_REPO="${MAIN_REPO:-/source-repo}"
WORKER_BRANCH="${WORKER_BRANCH:-tests/worker-${WORKER_ID:-1}}"

cd /app

# Initialize from main repo if this is a fresh mount without .git
if [ ! -d ".git" ] && [ -d "$MAIN_REPO/.git" ]; then
  echo "[entrypoint] Initializing from main repo..."
  git init
  git remote add origin "$MAIN_REPO"
  git fetch origin --depth=1
fi

# Ensure we're on the right branch
if git rev-parse --verify "$WORKER_BRANCH" >/dev/null 2>&1; then
  git checkout "$WORKER_BRANCH"
else
  echo "[entrypoint] Creating branch $WORKER_BRANCH..."
  git checkout -B "$WORKER_BRANCH" 2>/dev/null || true
fi

# Install dependencies if needed (for Node.js projects)
if [ -f "package.json" ] && [ ! -d "node_modules" ]; then
  echo "[entrypoint] Installing dependencies..."
  npm ci --ignore-scripts 2>/dev/null || npm install --ignore-scripts
fi

echo "[entrypoint] Starting agent server on port 8080..."
exec opencode serve --port 8080
