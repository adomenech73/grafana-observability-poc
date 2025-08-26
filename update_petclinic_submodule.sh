#!/bin/bash

# Configuration
SUBMODULE_DIR="spring-petclinic-microservices"
SUBMODULE_BRANCH="otel-poc"  # Your feature branch
UPSTREAM_REMOTE="origin"     # Remote name for original repo
FORK_REMOTE="petclinicfork"  # Remote name for your fork

# Function to check if there are uncommitted changes
check_uncommitted_changes() {
    if [[ -n $(git status --porcelain) ]]; then
        echo "❌ There are uncommitted changes in $1. Please commit or stash them before proceeding."
        exit 1
    fi
}

# Function to check if branch exists and switch to it
ensure_branch() {
    local branch="$1"
    if git show-ref --quiet refs/heads/"$branch"; then
        git checkout "$branch"
    else
        echo "❌ Branch $branch does not exist. Creating it from $UPSTREAM_REMOTE/main..."
        git checkout -b "$branch" "$UPSTREAM_REMOTE/main"
    fi
}

# Check if we're in the root of the deployment repository
if [ ! -d "$SUBMODULE_DIR" ]; then
    echo "❌ Error: $SUBMODULE_DIR directory not found. Make sure you're in the root of your deployment repository."
    exit 1
fi

# Check for uncommitted changes in the main repository
check_uncommitted_changes "the main repository"

# Navigate to the submodule directory
cd "$SUBMODULE_DIR" || exit

# Check for uncommitted changes in the submodule
check_uncommitted_changes "the submodule"

# Fetch latest changes from both upstream and your fork
echo "📡 Fetching latest changes from upstream repository..."
git fetch "$UPSTREAM_REMOTE"
git fetch "$FORK_REMOTE"

# Ensure we're on the correct feature branch
echo "🔀 Switching to feature branch $SUBMODULE_BRANCH..."
ensure_branch "$SUBMODULE_BRANCH"

# Rebase the current branch onto the latest main
echo "🔄 Rebasing $SUBMODULE_BRANCH onto $UPSTREAM_REMOTE/main..."
if git rebase "$UPSTREAM_REMOTE/main"; then
    echo "✅ Rebase successful."

    # Push rebased changes to your fork (force push required after rebase)
    echo "📤 Pushing rebased changes to your fork..."
    git push "$FORK_REMOTE" "$SUBMODULE_BRANCH" --force-with-lease

else
    echo "❌ Rebase encountered conflicts. Please resolve them manually:"
    echo "   - Resolve conflicts in the files"
    echo "   - Run: git add <resolved-files>"
    echo "   - Run: git rebase --continue"
    echo "   - After resolving, push with: git push $FORK_REMOTE $SUBMODULE_BRANCH --force-with-lease"
    exit 1
fi

# Go back to the main repository
cd ..

# Update the submodule reference in the main repository
echo "📦 Updating submodule reference in the main repository..."
git add "$SUBMODULE_DIR"
git commit -m "chore: update $SUBMODULE_DIR submodule to latest rebased version

Updated to include latest upstream changes rebased with our $SUBMODULE_BRANCH features.
- Synced with upstream main branch
- Maintained OpenTelemetry instrumentation changes
- Resolved any merge conflicts"

echo "🚀 Submodule update complete!"
echo ""
echo "Next steps:"
echo "1. Push main repository changes: git push origin main"
echo "2. Verify the build: ./mvnw clean install -P buildDocker"
echo "3. Test your OpenTelemetry changes are still working"
