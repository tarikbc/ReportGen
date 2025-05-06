#!/bin/bash

# Make sure variables don't leak to the environment if the script is sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Determine the directory where the script is located, even if it's a symlink
  SCRIPT_PATH="$(readlink -f "$0")"
  SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

  # Check if lib directory exists and make the scripts executable if needed
  if [ -d "$SCRIPT_DIR/lib" ]; then
    # Check if any of the lib scripts are not executable
    for script in "$SCRIPT_DIR"/lib/*.sh; do
      if [ -f "$script" ] && [ ! -x "$script" ]; then
        echo "Making lib scripts executable..."
        chmod +x "$SCRIPT_DIR"/lib/*.sh
        break
      fi
    done
  fi

  # Handle the --update flag before loading modules (for compatibility during the transition)
  if [[ "$1" == "--update" ]]; then
    # TRANSITIONAL CODE: This function exists to handle updates from the old monolithic
    # version to the new modular structure. It can be removed in a future version once
    # all users have migrated to the modular version. Until then, DO NOT REMOVE this
    # function or users with the old version won't be able to update.
    update_reportgen_transitional() {
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
    
    # Run the transitional update function
    update_reportgen_transitional
    exit $?
  fi

  # Source the modules (only if not updating, to avoid errors during transition)
  # Use a subshell to avoid leaking variables to the environment
  reportgen_execute() {
    source "$SCRIPT_DIR/lib/config.sh"
    source "$SCRIPT_DIR/lib/prompts.sh"
    source "$SCRIPT_DIR/lib/api.sh"
    source "$SCRIPT_DIR/lib/git.sh"
    source "$SCRIPT_DIR/lib/utils.sh"
    source "$SCRIPT_DIR/lib/update.sh"

    # Main entry point
    reportgen_main() {
      # Check if --update flag is passed (redundant with the check above, but kept for clarity)
      if [[ "$1" == "--update" ]]; then
        update_reportgen
        return $?
      fi

      # Load environment variables
      load_env

      # Check for updates when running normally
      (check_for_updates) &

      # Get optional commit argument
      local COMMIT_HASH="$1"

      # Check if content is being piped to the script
      local PIPED_CONTENT=""
      if [ -t 0 ]; then
        # No content is being piped in
        PIPED_CONTENT=""
      else
        # Read from stdin if data is being piped
        PIPED_CONTENT=$(cat)
      fi

      # Get diff content
      local diff_content=$(get_diff_content "$COMMIT_HASH" "$PIPED_CONTENT")
      
      if [ -z "$diff_content" ]; then
        echo "No changes detected."
        return 0
      fi

      # Debug: show how much content was retrieved
      local content_lines=$(echo "$diff_content" | wc -l)
      echo "Obtained $content_lines lines of diff content"

      if [ "$DEBUG" = "true" ]; then
        echo -e "\n[DEBUG] First 30 lines of diff content:"
        echo "$diff_content" | head -n 30
        echo -e "...(truncated)..."
      fi

      # Generate a summary of all changes
      echo -e "\n===== CHANGE SUMMARY ====="
      local change_summary=$(generate_summary "$diff_content")
      echo "$change_summary"

      # Generate and display suggestions
      echo -e "\n===== SUGGESTED GIT COMMIT & BRANCH ====="
      # Use a separate section for suggestions based on the change summary
      local suggestions=$(generate_suggestions "$change_summary")
      echo "$suggestions"

      # Display token usage and cost information
      display_usage_summary
      
      return 0
    }

    # Run the main function with all arguments
    reportgen_main "$@"
    return $?
  }

  # Execute the function with all arguments
  reportgen_execute "$@"
  exit $?
fi

# If this script is sourced, this section will execute
# This is useful for testing or for scripts that want to import functions
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  echo "ReportGen is being sourced, not executed directly."
  # No actions needed when sourced
fi