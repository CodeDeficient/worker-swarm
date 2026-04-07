#!/bin/bash
# scripts/auto-test-rounds.sh
# Runs N rounds of parallel worker tasks autonomously.
#
# This is an optional full-automation script. Adapt it to your task
# (test generation, refactoring, bug fixes, etc.).
#
# Usage: ./scripts/auto-test-rounds.sh [num_workers] [num_rounds] [model]

set -euo pipefail

NUM_WORKERS="${1:-6}"
NUM_ROUNDS="${2:-4}"
MODEL="${3:-minimax-coding-plan/MiniMax-M2.7}"
MAIN_REPO="$(git rev-parse --show-toplevel)"
BASE_BRANCH="main"

echo "========================================="
echo "  Auto Test Rounds"
echo "========================================="
echo "  Workers:  $NUM_WORKERS"
echo "  Rounds:   $NUM_ROUNDS"
echo "  Model:    $MODEL"
echo "  Repo:     $MAIN_REPO"
echo "========================================="
echo ""

for round in $(seq 1 "$NUM_ROUNDS"); do
  echo "=== Round $round of $NUM_ROUNDS ==="

  # 1. Generate file list (example: use coverage report)
  echo "Generating file list..."
  cd "$MAIN_REPO"
  # npx jest --coverage --coverageReporters=json --silent 2>/dev/null || true
  # node scripts/assign-files-to-workers.js "$NUM_WORKERS"  # outputs /tmp/worker-N-files.txt

  # 2. Sync workers to latest
  for i in $(seq 1 "$NUM_WORKERS"); do
    cd "${MAIN_REPO}-wt-${i}"
    git fetch "$MAIN_REPO" HEAD
    git reset --hard FETCH_HEAD
    git checkout -B "tests/worker-${i}"
  done

  # 3. Launch workers in parallel
  cd "$MAIN_REPO"
  for i in $(seq 1 "$NUM_WORKERS"); do
    PORT=$((8080 + i))
    # FILES=$(cat "/tmp/worker-${i}-files.txt" 2>/dev/null || echo "")
    opencode run \
      --attach "http://localhost:${PORT}" \
      -m "$MODEL" \
      --format json \
      --title "Round ${round} Worker ${i}" \
      "Your task prompt here. Files to work on go here." \
      > "/tmp/w${i}.log" 2>&1 &
  done

  # 4. Wait for workers (max 45 minutes)
  echo "Waiting for workers (max 45 minutes)..."
  sleep 2700

  # 5. Commit any uncommitted changes in worker clones
  for i in $(seq 1 "$NUM_WORKERS"); do
    cd "${MAIN_REPO}-wt-${i}"
    if [ -n "$(git status --porcelain)" ]; then
      git add -A && git commit -m "test: round $round worker $i remaining changes"
    fi
  done

  # 6. Merge all worker branches into a merge branch
  cd "$MAIN_REPO"
  git checkout -b "test/merge-round-${round}" "$BASE_BRANCH" 2>/dev/null \
    || git checkout "test/merge-round-${round}"
  for i in $(seq 1 "$NUM_WORKERS"); do
    git fetch "wt-${i}" "tests/worker-${i}" || continue
    git merge "wt-${i}/tests/worker-${i}" \
      -m "Merge round $round worker $i" --no-edit || {
        echo "Conflict on worker ${i}, accepting theirs for test files"
        git checkout --theirs -- .
        git add -A
        git commit -m "Merge round $round worker $i (conflict resolved)" --no-edit
      }
  done

  # 7. Run tests to verify
  echo "Running tests..."
  # npm test -- --silent 2>&1 | tail -5

  # 8. Push merge branch
  git push origin "test/merge-round-${round}" 2>/dev/null || echo "Push skipped (no remote?)"

  echo "=== Round $round complete ==="
  echo ""
done

echo "=== All $NUM_ROUNDS rounds complete ==="
