#!/bin/bash

# Determine the directory where the script is located, even if it's a symlink
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Check if --update flag is passed
if [[ "$1" == "--update" ]]; then
  echo "Updating ReportGen to the latest version..."
  
  # Store current directory to return to it later
  CURRENT_DIR=$(pwd)
  
  # Navigate to script directory
  cd "$SCRIPT_DIR"
  
  # Check if we're in a git repository
  if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    # Get current branch
    CURRENT_BRANCH=$(git branch --show-current)
    
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
        exit 1
      fi
    fi
    
    # Pull the latest version
    git checkout main && git pull origin main
    
    # Return to original branch if different
    if [[ "$CURRENT_BRANCH" != "main" && -n "$CURRENT_BRANCH" ]]; then
      git checkout "$CURRENT_BRANCH"
    fi
    
    echo "ReportGen has been updated to the latest version."
  else
    echo "Error: Not a git repository. Cannot update."
    exit 1
  fi
  
  # Return to original directory
  cd "$CURRENT_DIR"
  exit 0
fi

# Load environment variables from .env file in the script's directory
set -o allexport
source "$SCRIPT_DIR/.env"
set +o allexport

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

# Check for updates in the background to not slow down execution
(check_for_updates) &

MAX_CHARACTERS=4000  # Set max characters per OpenAI API call

# Pricing per 1K tokens (in USD)
GPT4O_MINI_INPUT_PRICE=0.00015  # $0.15 per 1K tokens
GPT4O_MINI_OUTPUT_PRICE=0.00060 # $0.60 per 1K tokens

# Counters for token usage
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0
TOTAL_COST=0

# Check for the OpenAI API key environment variable
if [ -z "$OPENAI_API_KEY" ]; then
  echo "Error: OPENAI_API_KEY is not set. Please export your API key in the .env file."
  exit 1
fi

# Get optional commit argument
COMMIT_HASH="$1"

# String to hold partial summaries from each chunk
ALL_PARTIAL_SUMMARIES=""

#######################################
# Send a chunk of diff to OpenAI and
# retrieve a partial summary.
#######################################
send_to_openai() {
  local diff_summary_content="$1"
  
  # Sanitize the diff summary
  local sanitized_diff_summary
  sanitized_diff_summary=$(echo "$diff_summary_content" | sed 's/[^a-zA-Z0-9+ ,.:;()_\[\]{}\/@-]//g')

  # Create JSON request body
  local request_body
  request_body=$(jq -n \
    --arg system "You are a tool that summarizes git diffs into concise, human-readable topics." \
    --arg examples "Focus on interpreting what the code change does to come up with the topic.\nTry to reference the component name in the topic.\nDon't create topics that are too long-winded.\nDon't create topics that are too vague.\nExamples:\n- Added new type definitions for Tutor entity\n- Refactored TutorItem props\n- Updated TutorsList component\n- Extended Tutor schema with voting fields\n- Enhanced button properties in Tutors component" \
    --arg diff "$sanitized_diff_summary" \
    '{
      "model": "gpt-4o-mini",
      "messages": [
        {
          "role": "system",
          "content": $system
        },
        {
          "role": "user",
          "content": $examples
        },
        {
          "role": "user",
          "content": $diff
        }
      ],
      "max_tokens": 2000,
      "temperature": 0.5
    }'
  )

  # Send request and capture response
  local response
  response=$(curl -s https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$request_body" | jq -c .)

  # Update token usage counters
  local prompt_tokens=$(echo "$response" | jq -r '.usage.prompt_tokens // 0')
  local completion_tokens=$(echo "$response" | jq -r '.usage.completion_tokens // 0')
  
  TOTAL_INPUT_TOKENS=$((TOTAL_INPUT_TOKENS + prompt_tokens))
  TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + completion_tokens))
  
  # Calculate cost for this request
  local input_cost=$(echo "$prompt_tokens * $GPT4O_MINI_INPUT_PRICE / 1000" | bc -l)
  local output_cost=$(echo "$completion_tokens * $GPT4O_MINI_OUTPUT_PRICE / 1000" | bc -l)
  local request_cost=$(echo "$input_cost + $output_cost" | bc -l)
  TOTAL_COST=$(echo "$TOTAL_COST + $request_cost" | bc -l)

  # Parse JSON
  local text
  text=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'error' in data:
    print('Error:', data['error']['message'])
else:
    print(data['choices'][0]['message']['content'])
" <<< "$response")

  echo "$text"
}

#######################################
# Final summarization with "no bullshit" prompt
#######################################
final_summarize() {
  local all_summaries="$1"

  local request_body
  request_body=$(jq -n \
    --arg system "You are an assistant that refines multiple partial summaries into concise bullet points." \
    --arg userprompt "Filter out useless and condense the most important topics so it doesn't look like bullshit (IF ANY. RETURN TOPICS ONLY):" \
    --arg summaries "$all_summaries" \
    '{
      "model": "gpt-4o-mini",
      "messages": [
        {
          "role": "system",
          "content": $system
        },
        {
          "role": "user",
          "content": $userprompt
        },
        {
          "role": "user",
          "content": $summaries
        }
      ],
      "max_tokens": 2000,
      "temperature": 0.5
    }'
  )

  local response
  response=$(curl -s https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$request_body" | jq -c .)
    
  # Update token usage counters
  local prompt_tokens=$(echo "$response" | jq -r '.usage.prompt_tokens // 0')
  local completion_tokens=$(echo "$response" | jq -r '.usage.completion_tokens // 0')
  
  TOTAL_INPUT_TOKENS=$((TOTAL_INPUT_TOKENS + prompt_tokens))
  TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + completion_tokens))
  
  # Calculate cost for this request
  local input_cost=$(echo "$prompt_tokens * $GPT4O_MINI_INPUT_PRICE / 1000" | bc -l)
  local output_cost=$(echo "$completion_tokens * $GPT4O_MINI_OUTPUT_PRICE / 1000" | bc -l)
  local request_cost=$(echo "$input_cost + $output_cost" | bc -l)
  TOTAL_COST=$(echo "$TOTAL_COST + $request_cost" | bc -l)

  local final_text
  final_text=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'error' in data:
    print('Error:', data['error']['message'])
else:
    print(data['choices'][0]['message']['content'])
" <<< "$response")

  echo "$final_text"
}

# Determine changed files based on commit hash or current diff
if [ -n "$COMMIT_HASH" ]; then
  changed_files=$(git diff --name-only "$COMMIT_HASH~" "$COMMIT_HASH")
else
  changed_files=$(git diff --name-only)
fi

# Exit if there's no diff
if [ -z "$changed_files" ]; then
  echo "No changes detected."
  exit 0
fi

diff_summary=""

#########################################
# Process diffs and show partial outputs
#########################################
echo -e "\n===== PARTIAL TOPICS ====="
for file in $changed_files; do
    if [ -n "$COMMIT_HASH" ]; then
        file_diff=$(git diff "$COMMIT_HASH~" "$COMMIT_HASH" -- "$file")
    else
        file_diff=$(git diff -- "$file")
    fi

    diff_summary="$diff_summary\n\nFile: $file\nDiff Summary:\n$file_diff"

    # If chunk is large enough, get partial summary now
    if [ ${#diff_summary} -ge $MAX_CHARACTERS ]; then
        partial_topics=$(send_to_openai "$diff_summary")
        echo "$partial_topics"

        # Accumulate partial summaries
        ALL_PARTIAL_SUMMARIES="$ALL_PARTIAL_SUMMARIES\n$partial_topics"
        diff_summary=""
    fi
done

# Handle any remaining chunk
if [ -n "$diff_summary" ]; then
  partial_topics=$(send_to_openai "$diff_summary")
  echo "$partial_topics"

  ALL_PARTIAL_SUMMARIES="$ALL_PARTIAL_SUMMARIES\n$partial_topics"
fi

# Now do the final "no bullshit" summarization
echo -e "\n\n"
echo -e "\n===== FINAL FILTERED TOPICS ====="
final_summarize "$ALL_PARTIAL_SUMMARIES"

# Display token usage and cost information
echo -e "\n===== USAGE SUMMARY ====="
echo "Input tokens: $TOTAL_INPUT_TOKENS"
echo "Output tokens: $TOTAL_OUTPUT_TOKENS"
echo "Total tokens: $((TOTAL_INPUT_TOKENS + TOTAL_OUTPUT_TOKENS))"

# Calculate total cost in a way that preserves precision
input_cost=$(echo "scale=10; $TOTAL_INPUT_TOKENS * $GPT4O_MINI_INPUT_PRICE / 1000" | bc)
output_cost=$(echo "scale=10; $TOTAL_OUTPUT_TOKENS * $GPT4O_MINI_OUTPUT_PRICE / 1000" | bc)
TOTAL_COST=$(echo "scale=10; $input_cost + $output_cost" | bc)

# Format cost with simple rounding to show appropriate significant digits
if (( $(echo "$TOTAL_COST == 0" | bc -l) )); then
  formatted_cost="$0.00"
elif (( $(echo "$TOTAL_COST >= 0.01" | bc -l) )); then
  # For costs >= $0.01, show 2 decimal places
  formatted_cost=$(printf "$%.2f" "$TOTAL_COST")
elif (( $(echo "$TOTAL_COST >= 0.001" | bc -l) )); then
  # For costs >= $0.001, show 3 decimal places
  formatted_cost=$(printf "$%.3f" "$TOTAL_COST")
elif (( $(echo "$TOTAL_COST >= 0.0001" | bc -l) )); then
  # For costs >= $0.0001, show 4 decimal places
  formatted_cost=$(printf "$%.4f" "$TOTAL_COST")
else
  # For very small costs, round to 5 significant digits
  # First convert to scientific notation
  sci_notation=$(printf "%.10e" "$TOTAL_COST")
  
  # Extract mantissa and exponent
  mantissa=$(echo "$sci_notation" | sed -E 's/([0-9]+\.[0-9]+)e.*/\1/')
  exponent=$(echo "$sci_notation" | sed -E 's/.*e-?([0-9]+)/\1/')
  sign=$(echo "$sci_notation" | grep -o 'e-' || echo "e+")
  
  if [ "$sign" = "e-" ]; then
    # For negative exponents, show rounded decimal
    rounded_mantissa=$(printf "%.5g" "$mantissa" | sed 's/\.0*$//')
    rounded_cost=$(echo "scale=10; $rounded_mantissa * 10^-$exponent" | bc -l)
    
    # Determine decimal places needed (exponent + 1 to show first significant digit)
    decimal_places=$((exponent + 1))
    if [ "$decimal_places" -gt 10 ]; then
      decimal_places=10  # Cap at 10 decimal places for readability
    fi
    
    # Format with appropriate number of decimal places
    formatted_cost=$(printf "$%.*f" "$decimal_places" "$rounded_cost")
    
    # Trim trailing zeros
    formatted_cost=$(echo "$formatted_cost" | sed 's/\.0*$//' | sed 's/\.\([0-9]*[1-9]\)0*$/.\1/')
    
    # Ensure we have at least 1 decimal place for small numbers
    if [[ ! "$formatted_cost" =~ \. ]]; then
      formatted_cost="$formatted_cost.0"
    fi
  else
    # For positive exponents, use standard format
    formatted_cost=$(printf "$%.2f" "$TOTAL_COST")
  fi
fi

echo "Cost: $formatted_cost USD"