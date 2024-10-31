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

# Function to send diff summary to OpenAI API
send_to_openai() {
  # echo "Sending ${#1} characters to OpenAI API..."
  local diff_summary_content="$1"
  
  # Sanitize the diff summary
  local sanitized_diff_summary=$(echo "$diff_summary_content" | sed 's/[^a-zA-Z0-9+ -]//g')

  # Use jq to format the JSON request body with roles and content
  local request_body=$(jq -n --arg system "You are a tool that summarizes git diffs into concise, human-readable topics." \
                            --arg examples "Focus on interpreting what the code change does to come up with the topic.\nTry to reference the component name in the topic.\nDon't create topics that are too long-winded.\nDon't create topics that are too vague.\n Examples of expected output topics:\n- Added new type definitions for Tutor entity in Tutors component\n- Refactored TutorItem props for improved type safety\n- Updated TutorsList component to handle missing index\n- Extended Tutor schema with voting fields (positiveVotes, neutralVotes, negativeVotes)\n- Enhanced button properties in Tutors component for accessibility" \
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
      }')

  # Send the request to OpenAI's API and capture the response
  local response=$(curl -s https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$request_body" | jq -c .)

  # Use Python to parse the JSON and handle errors if they exist
  local text=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'error' in data:
    print('Error:', data['error']['message'])
else:
    print(data['choices'][0]['message']['content'])
" <<< "$response")

  # Display the concise topics
  echo "$text"
}

# Get the list of changed files
changed_files=$(git diff --name-only)

# Exit if there's no diff
if [ -z "$changed_files" ]; then
  echo "No changes detected."
  exit 0
fi

# Generate the full diff summary content
diff_summary=""
for file in $changed_files; do
    # Get the full diff without line limits
    file_diff=$(git diff "$file")
    
    # Append each full diff to the diff content
    diff_summary="$diff_summary\n\nFile: $file\nDiff Summary:\n$file_diff"

    # Check if we hit the character limit
    if [ ${#diff_summary} -ge $MAX_CHARACTERS ]; then
        send_to_openai "$diff_summary"
        diff_summary=""  # Reset diff summary after sending
    fi
done

# Send any remaining content if not empty
if [ -n "$diff_summary" ]; then
  send_to_openai "$diff_summary"
fi