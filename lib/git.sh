#!/bin/bash

# Git-related functions

# Check for updates when running normally
check_for_updates() {
  # Only check in git repositories and don't block execution with errors
  if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    return
  fi
  
  # Save current directory
  local current_dir=$(pwd)
  cd "$SCRIPT_DIR"
  
  # Quietly fetch to see if there are updates
  git fetch origin main --quiet 2>/dev/null
  
  # Compare local with remote
  local local_commit=$(git rev-parse HEAD 2>/dev/null)
  local remote_commit=$(git rev-parse origin/main 2>/dev/null)
  
  if [ "$local_commit" != "$remote_commit" ] && [ -n "$remote_commit" ]; then
    echo -e "\033[33m📢 Updates available! Run 'reportgen --update' to get the latest version.\033[0m"
  fi
  
  # Return to original directory
  cd "$current_dir"
}

# Get diff content from commit hash or unstaged/staged changes
get_diff_content() {
  local commit_hash="$1"
  local piped_content="$2"
  
  if [ -n "$piped_content" ]; then
    # Use piped content directly
    echo "Processing piped content for analysis..."
    echo "$piped_content"
    return
  fi
  
  if [ -n "$commit_hash" ]; then
    echo "Analyzing commit: $commit_hash"
    
    # First, verify the commit exists
    if ! git cat-file -e "$commit_hash" 2>/dev/null; then
      echo "Error: Commit $commit_hash does not exist."
      return
    fi
    
    # Get raw git diff output with full context
    local diff_content=$(git show --stat --patch "$commit_hash")
    
    # Exit if there's no diff
    if [ -z "$diff_content" ]; then
      echo "No changes detected in commit $commit_hash."
      return
    fi
    
    echo "Retrieved changes from commit $commit_hash"
    echo "$diff_content"
    return
  fi
  
  echo "Analyzing uncommitted changes..."
  
  # Try unstaged changes first
  local diff_content=$(git diff --stat --patch)
  
  # If no unstaged changes, try staged changes
  if [ -z "$diff_content" ] || [ "$diff_content" = "$(echo -e "\n")" ]; then
    diff_content=$(git diff --cached --stat --patch)
    
    # If still no changes, exit
    if [ -z "$diff_content" ] || [ "$diff_content" = "$(echo -e "\n")" ]; then
      echo "No uncommitted or staged changes detected."
      return
    fi
    
    echo "Retrieved staged changes"
  else
    echo "Retrieved unstaged changes"
  fi
  
  echo "$diff_content"
} 