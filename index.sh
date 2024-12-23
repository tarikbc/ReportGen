#!/bin/bash

# Determine the directory where the script is located, even if it's a symlink
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Load environment variables from .env file in the script's directory
set -o allexport
source "$SCRIPT_DIR/.env"
set +o allexport

MAX_CHARACTERS=4000  # Set max characters per OpenAI API call

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
  sanitized_diff_summary=$(echo "$diff_summary_content" | sed 's/[^a-zA-Z0-9+ ,.:;()\-_\[\]{}\/@]//g')

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