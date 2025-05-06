#!/bin/bash

# Configuration variables and environment loading

# Prefix all variables with rg_ to avoid namespace collisions
# These are intentionally not declared with 'local' since they need to be accessible to other modules

# Maximum characters for API calls
rg_MAX_CHARACTERS=16000

# Pricing per 1K tokens (in USD)
rg_GPT4O_INPUT_PRICE=0.00015  # $0.15 per 1K tokens
rg_GPT4O_OUTPUT_PRICE=0.00060 # $0.60 per 1K tokens

# Counters for token usage
rg_TOTAL_INPUT_TOKENS=0
rg_TOTAL_OUTPUT_TOKENS=0
rg_TOTAL_COST=0

# Debug mode
rg_DEBUG=${DEBUG:-false}

# Load environment variables from .env file in the script's directory
load_env() {
  set -o allexport
  source "$SCRIPT_DIR/.env"
  set +o allexport
  
  # Check for the OpenAI API key environment variable
  if [ -z "$OPENAI_API_KEY" ]; then
    echo "Error: OPENAI_API_KEY is not set. Please export your API key in the .env file."
    return 1
  fi
  
  return 0
}

# Debug helper function
debug_info() {
  if [ -n "$rg_DEBUG" ] && [ "$rg_DEBUG" = "true" ]; then
    echo -e "\n[DEBUG] $1"
  fi
} 