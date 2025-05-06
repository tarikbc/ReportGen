#!/bin/bash

# Update functionality for ReportGen

# Update ReportGen to the latest version
update_reportgen() {
  echo "Updating ReportGen to the latest version..."
  
  # Store current directory to return to it later
  local CURRENT_DIR=$(pwd)
  
  # Navigate to script directory
  cd "$SCRIPT_DIR"
  
  # Check if we're in a git repository
  if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    # Get current branch
    local CURRENT_BRANCH=$(git branch --show-current)
    
    # Fetch latest changes
    git fetch origin main
    
    # Check for any local changes
    if ! git diff-index --quiet HEAD --; then
      echo "Warning: You have local changes that would be overwritten."
      read -p "Continue with update anyway? (y/N): " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Update cancelled."
        cd "$CURRENT_DIR"
        return 1
      fi
    fi
    
    # Pull the latest version
    git checkout main && git pull origin main
    
    # Make sure all scripts are executable (especially for users updating from old version)
    chmod +x "$SCRIPT_DIR/index.sh"
    if [ -d "$SCRIPT_DIR/lib" ]; then
      chmod +x "$SCRIPT_DIR"/lib/*.sh
      echo "Made lib scripts executable."
    fi
    
    # Return to original branch if different
    if [[ "$CURRENT_BRANCH" != "main" && -n "$CURRENT_BRANCH" ]]; then
      git checkout "$CURRENT_BRANCH"
    fi
    
    echo "ReportGen has been updated to the latest version."
  else
    echo "Error: Not a git repository. Cannot update."
    return 1
  fi
  
  # Return to original directory
  cd "$CURRENT_DIR"
  return 0
} 