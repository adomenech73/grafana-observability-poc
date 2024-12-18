#!/bin/bash

# Name of the submodule directory
SUBMODULE_DIR="spring-petclinic-microservices"

# Function to check if there are uncommitted changes
check_uncommitted_changes() {
    if [[ -n $(git status -s) ]]; then
        echo "There are uncommitted changes in $1. Please commit or stash them before proceeding."
        exit 1
    fi
}

# Check if we're in the root of the deployment repository
if [ ! -d "$SUBMODULE_DIR" ]; then
    echo "Error: $SUBMODULE_DIR directory not found. Make sure you're in the root of your deployment repository."
    exit 1
fi

# Check for uncommitted changes in the main repository
check_uncommitted_changes "the main repository"

# Navigate to the submodule directory
cd "$SUBMODULE_DIR" || exit

# Check for uncommitted changes in the submodule
check_uncommitted_changes "the submodule"

# Fetch the latest changes from the original repository
echo "Fetching latest changes from the original repository..."
git fetch origin

# Store the current branch name
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# If we're not on a branch (detached HEAD), create a temporary branch
if [ "$CURRENT_BRANCH" == "HEAD" ]; then
    CURRENT_BRANCH="temp-rebase-branch-$(date +%s)"
    git checkout -b "$CURRENT_BRANCH"
fi

# Rebase the current branch onto the latest main
echo "Rebasing $CURRENT_BRANCH onto origin/main..."
if git rebase origin/main; then
    echo "Rebase successful."
else
    echo "Rebase encountered conflicts. Please resolve them manually, then run 'git rebase --continue'."
    echo "After resolving conflicts, don't forget to push your changes and update the submodule reference in the main repository."
    exit 1
fi

# Go back to the main repository
cd ..

# Update the submodule reference in the main repository
echo "Updating submodule reference in the main repository..."
git add "$SUBMODULE_DIR"
git commit -m "Update $SUBMODULE_DIR submodule to latest commit with rebased changes"

echo "Submodule update complete. Don't forget to push your changes to both repositories."
