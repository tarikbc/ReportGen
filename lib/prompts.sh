#!/bin/bash

# Prompts used by the application
# These are intentionally not declared with 'local' since they need to be accessible to other modules
SYSTEM_PROMPT=""
USER_PROMPT=""
SUGGESTION_SYSTEM_PROMPT=""
SUGGESTION_USER_PROMPT=""

# Load prompts from the JSON file
load_prompts() {
  if [ ! -f "$SCRIPT_DIR/prompts.json" ]; then
    echo "Error: prompts.json file not found in $SCRIPT_DIR"
    return 1
  fi
  
  # Use jq to extract prompt components
  SYSTEM_PROMPT=$(jq -r '.summary.system' "$SCRIPT_DIR/prompts.json")
  USER_PROMPT=$(jq -r '.summary.prompt' "$SCRIPT_DIR/prompts.json")
  
  # Load suggestion prompts
  SUGGESTION_SYSTEM_PROMPT=$(jq -r '.suggestions.system' "$SCRIPT_DIR/prompts.json")
  SUGGESTION_USER_PROMPT=$(jq -r '.suggestions.prompt' "$SCRIPT_DIR/prompts.json")
  
  # Check if any prompt is empty
  if [ -z "$SYSTEM_PROMPT" ] || [ -z "$USER_PROMPT" ] || 
     [ -z "$SUGGESTION_SYSTEM_PROMPT" ] || [ -z "$SUGGESTION_USER_PROMPT" ]; then
    echo "Error: One or more prompts are empty in prompts.json"
    return 1
  fi
  
  return 0
}

# Load prompts at script initialization
load_prompts 