#!/bin/bash
# scripts/cleanup-worker-clones.sh
# Removes worker clone directories and deletes their branches.
#
# Usage: ./scripts/cleanup-worker-clones.sh [num_workers]

set -euo pipefail

NUM_WORKERS="${1:-6}"
MAIN_REPO="$(git rev-parse --show-toplevel)"

echo "========================================="
echo "  Worker Clone Cleanup"
echo "========================================="
echo ""

for i in $(seq 1 "$NUM_WORKERS"); do
  CLONE_DIR="${MAIN_REPO}-wt-${i}"
  WORKER_BRANCH="tests/worker-${i}"

  if [ -d "$CLONE_DIR/.git" ]; then
    echo "[$i] Removing clone at $CLONE_DIR..."
    rm -rf "$CLONE_DIR"
    echo "     Clone removed."
  else
    echo "[$i] No clone found at $CLONE_DIR, skipping."
  fi

  # Remove remote from main repo
  if git -C "$MAIN_REPO" remote | grep -q "wt-${i}"; then
    git -C "$MAIN_REPO" remote remove "wt-${i}"
    echo "     Remote wt-${i} removed."
  fi

  # Delete branch if it exists
  if git -C "$MAIN_REPO" rev-parse --verify "$WORKER_BRANCH" >/dev/null 2>&1; then
    git -C "$MAIN_REPO" branch -d "$WORKER_BRANCH" 2>/dev/null \
      || git -C "$MAIN_REPO" branch -D "$WORKER_BRANCH" 2>/dev/null \
      || true
    echo "     Branch $WORKER_BRANCH deleted."
  fi
done

echo ""
echo "========================================="
echo "  Cleanup complete."
echo "========================================="
