#!/bin/bash
# Sync fork with upstream, keeping our customizations on top
#
# Usage: bin/sync-upstream.sh
#
# This script:
# 1. Fetches latest from upstream (statickidz/dokploy-oci-free)
# 2. Rebases our main onto upstream/main
# 3. Force-pushes to origin (our fork)
#
# Our commits stay on top of upstream's commits, making it clear
# what we've customized vs what came from upstream.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[sync]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
error() { echo -e "${RED}[error]${NC} $1"; exit 1; }

# Ensure we're on main
CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    warn "Currently on '$CURRENT_BRANCH', switching to main..."
    git checkout main
fi

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    error "Uncommitted changes detected. Commit or stash them first."
fi

log "Fetching upstream..."
git fetch upstream

# Show what's new from upstream
NEW_COMMITS=$(git log --oneline main..upstream/main | wc -l | tr -d ' ')
if [[ "$NEW_COMMITS" == "0" ]]; then
    log "Already up to date with upstream/main"
    exit 0
fi

log "Found $NEW_COMMITS new commits from upstream"
git log --oneline main..upstream/main

log "Rebasing main onto upstream/main..."
if ! git rebase upstream/main; then
    error "Rebase failed. Resolve conflicts, then run: git rebase --continue"
fi

log "Force-pushing to origin..."
git push origin main --force-with-lease

log "Sync complete! Your customizations are on top of upstream."
