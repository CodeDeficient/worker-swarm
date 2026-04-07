#!/bin/bash
# scripts/init-worker-clones.sh
# Creates independent git clones for each worker container.
# Each clone is a fully isolated copy of the repo on its own branch.
#
# Usage: ./scripts/init-worker-clones.sh [num_workers] [base_branch]
#   num_workers  — number of worker clones to create (default: 6)
#   base_branch  — branch to fork worker branches from (default: main)

set -euo pipefail

NUM_WORKERS="${1:-6}"
BASE_BRANCH="${2:-main}"
MAIN_REPO="$(git rev-parse --show-toplevel)"

echo "========================================="
echo "  Worker Clone Initializer"
echo "========================================="
echo "  Repo root:    $MAIN_REPO"
echo "  Base branch:  $BASE_BRANCH"
echo "  Workers:      $NUM_WORKERS"
echo "========================================="
echo ""

for i in $(seq 1 "$NUM_WORKERS"); do
  CLONE_DIR="${MAIN_REPO}-wt-${i}"
  WORKER_BRANCH="tests/worker-${i}"

  if [ -d "$CLONE_DIR/.git" ]; then
    CURRENT_BRANCH="$(git -C "$CLONE_DIR" branch --show-current)"
    echo "[$i] Clone exists at $CLONE_DIR → branch: $CURRENT_BRANCH"
  else
    # Create worker branch from base
    if ! git rev-parse --verify "$WORKER_BRANCH" >/dev/null 2>&1; then
      echo "[$i] Creating branch $WORKER_BRANCH from $BASE_BRANCH..."
      git branch "$WORKER_BRANCH" "$BASE_BRANCH"
    fi

    # Remove leftover directory if present
    if [ -d "$CLONE_DIR" ]; then
      echo "[$i] Cleaning up leftover directory..."
      rm -rf "$CLONE_DIR"
    fi

    echo "[$i] Cloning to $CLONE_DIR..."
    git clone --single-branch --branch "$WORKER_BRANCH" "$MAIN_REPO" "$CLONE_DIR"

    # Add as remote on main repo for easy merging
    if ! git -C "$MAIN_REPO" remote | grep -q "wt-${i}"; then
      git -C "$MAIN_REPO" remote add "wt-${i}" "$CLONE_DIR"
      echo "[$i] Added remote wt-${i}"
    fi

    echo "[$i] Ready."
  fi
  echo ""
done

echo "========================================="
echo "  Summary"
echo "========================================="
for i in $(seq 1 "$NUM_WORKERS"); do
  CLONE_DIR="${MAIN_REPO}-wt-${i}"
  if [ -d "$CLONE_DIR/.git" ]; then
    BRANCH="$(git -C "$CLONE_DIR" branch --show-current)"
    echo "  [$i] $CLONE_DIR → $BRANCH"
  else
    echo "  [$i] $CLONE_DIR → NOT READY"
  fi
done

echo ""
echo "To start workers:    docker compose -f docker-compose.opencode.yml up -d"
echo "To clean up clones:  ./scripts/cleanup-worker-clones.sh"
