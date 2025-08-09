#!/bin/bash

# Functions for interacting with OpenAI APIs

# Define model variables - using GPT-4.1 mini as the default model
DEFAULT_MODEL="gpt-4o"
rg_GPT41MINI_INPUT_PRICE=0.40
rg_GPT41MINI_CACHED_INPUT_PRICE=0.10
rg_GPT41MINI_OUTPUT_PRICE=1.60

# Define GPT-4o pricing (if used)
rg_GPT4O_INPUT_PRICE=0.01
rg_GPT4O_OUTPUT_PRICE=0.03

# Initialize token counters as global variables with export
export rg_TOTAL_INPUT_TOKENS=0
export rg_TOTAL_OUTPUT_TOKENS=0
export rg_TOTAL_COST=0

# Initialize and reset token counter file
TOKEN_FILE="/tmp/reportgen_token_counters.txt"
echo "0 0 0" > "$TOKEN_FILE"

#######################################
# Send git diff to OpenAI and get a summary.
#######################################
generate_summary() {
  local diff_content="$1"
  
  # Sanitize the diff summary
  local sanitized_diff
  sanitized_diff=$(echo "$diff_content" | sed 's/[^a-zA-Z0-9+ ,.:;()_\[\]{}\/@-]//g')

  # Create JSON request body
  local request_body
  request_body=$(jq -n \
    --arg system "$SYSTEM_PROMPT" \
    --arg user_prompt "$USER_PROMPT" \
    --arg diff "$sanitized_diff" \
    --arg model "$DEFAULT_MODEL" \
    '{
      "model": $model,
      "messages": [
        {
          "role": "system",
          "content": $system
        },
        {
          "role": "user",
          "content": $user_prompt
        },
        {
          "role": "user",
          "content": $diff
        }
      ],
      "max_tokens": 4000,
      "temperature": 0.3
    }'
  )

  # Send request and get response
  local response=$(call_openai_api "$request_body")
  
  # Parse and return response
  local result=$(parse_api_response "$response")
  echo "$result"
}

# Generate suggested commit message and branch name based on the change summary
generate_suggestions() {
  local changes="$1"
  
  # Skip if changes are empty
  if [ -z "$changes" ]; then
    echo "No changes to suggest commit message for."
    return
  fi
  
  # Create temp files for our changes, prompt template, and Python script
  local tmp_changes_file=$(mktemp)
  local tmp_prompt_template=$(mktemp)
  local tmp_python_script=$(mktemp)
  local tmp_output_file=$(mktemp)
  
  # Write content to temp files
  echo "$changes" > "$tmp_changes_file"
  echo "$SUGGESTION_USER_PROMPT" > "$tmp_prompt_template"
  
  # Create Python script that safely handles the replacement
  cat > "$tmp_python_script" << 'EOPY'
import sys

# Get file paths from arguments
template_file = sys.argv[1]
changes_file = sys.argv[2]
output_file = sys.argv[3]

# Read the files
with open(template_file, 'r') as f:
    template = f.read()
with open(changes_file, 'r') as f:
    changes = f.read()

# Replace the placeholder
result = template.replace('{changes}', changes)

# Write the result
with open(output_file, 'w') as f:
    f.write(result)
EOPY
  
  # Run the Python script
  python3 "$tmp_python_script" "$tmp_prompt_template" "$tmp_changes_file" "$tmp_output_file"
  
  # Read the formatted prompt
  local formatted_prompt
  formatted_prompt=$(<"$tmp_output_file")
  
  # Clean up temporary files
  rm -f "$tmp_changes_file" "$tmp_prompt_template" "$tmp_python_script" "$tmp_output_file"
  
  # Create request body
  local request_body
  request_body=$(jq -n \
    --arg system "$SUGGESTION_SYSTEM_PROMPT" \
    --arg user_prompt "$formatted_prompt" \
    --arg model "$DEFAULT_MODEL" \
    '{
      "model": $model,
      "messages": [
        {
          "role": "system",
          "content": $system
        },
        {
          "role": "user",
          "content": $user_prompt
        }
      ],
      "max_tokens": 200,
      "temperature": 0.3
    }'
  )

  # Send request and get response
  local response=$(call_openai_api "$request_body")
  
  # Parse and return response
  local result=$(parse_suggestion_response "$response")
  echo "$result"
}

# Common function to call OpenAI API
call_openai_api() {
  local request_body="$1"
  
  # Extract model from request body for pricing calculations
  local model=$(echo "$request_body" | jq -r '.model')
  
  # Send request and capture response
  local response
  response=$(curl -s https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$request_body" | jq -c .)
  
  # Check for errors in the response
  if echo "$response" | jq -e '.error' > /dev/null; then
    local error_message=$(echo "$response" | jq -r '.error.message')
    echo "Error from OpenAI API: $error_message" >&2
    return 1
  fi
  
  # Update token usage counters
  local prompt_tokens=0
  local completion_tokens=0
  
  # Try standard format first
  if echo "$response" | jq -e '.usage.prompt_tokens' > /dev/null; then
    prompt_tokens=$(echo "$response" | jq -r '.usage.prompt_tokens')
    completion_tokens=$(echo "$response" | jq -r '.usage.completion_tokens')
  # Try input/output tokens format
  elif echo "$response" | jq -e '.usage.input_tokens' > /dev/null; then
    prompt_tokens=$(echo "$response" | jq -r '.usage.input_tokens')
    completion_tokens=$(echo "$response" | jq -r '.usage.output_tokens')
  # Try other potential formats
  elif echo "$response" | jq -e '.usage.token_count' > /dev/null; then
    # Some APIs might use a different structure
    prompt_tokens=$(echo "$response" | jq -r '.usage.token_count.prompt // 0')
    completion_tokens=$(echo "$response" | jq -r '.usage.token_count.completion // 0')
  else
    echo "WARNING: Could not find token usage information in API response" >&2
    # Save the response for debugging
    echo "$response" > /tmp/api_response_debug.json
    prompt_tokens=0
    completion_tokens=0
  fi
  
  # Ensure we're dealing with numbers
  if [[ ! "$prompt_tokens" =~ ^[0-9]+$ ]]; then
    echo "WARNING: Invalid prompt_tokens value: $prompt_tokens" >&2
    prompt_tokens=0
  fi
  
  if [[ ! "$completion_tokens" =~ ^[0-9]+$ ]]; then
    echo "WARNING: Invalid completion_tokens value: $completion_tokens" >&2
    completion_tokens=0
  fi
  
  # Force conversion to integers
  prompt_tokens=$((prompt_tokens + 0))
  completion_tokens=$((completion_tokens + 0))
  
  # Use a token file to persist values between function calls
  TOKEN_FILE="/tmp/reportgen_token_counters.txt"
  
  # Read the current values
  read -r file_input_tokens file_output_tokens file_cost < "$TOKEN_FILE"
  
  # Ensure values are numbers
  [[ "$file_input_tokens" =~ ^[0-9]+$ ]] || file_input_tokens=0
  [[ "$file_output_tokens" =~ ^[0-9]+$ ]] || file_output_tokens=0
  [[ "$file_cost" =~ ^[0-9.]+$ ]] || file_cost=0
  
  # Update the counters
  file_input_tokens=$((file_input_tokens + prompt_tokens))
  file_output_tokens=$((file_output_tokens + completion_tokens))
  
  # Update global variables too for the current process
  export rg_TOTAL_INPUT_TOKENS=$file_input_tokens
  export rg_TOTAL_OUTPUT_TOKENS=$file_output_tokens
  
  # Calculate cost for this request based on model
  local input_price
  local output_price
  
  if [ "$model" = "gpt-4.1-mini" ]; then
    input_price=$rg_GPT41MINI_INPUT_PRICE
    output_price=$rg_GPT41MINI_OUTPUT_PRICE
  elif [ "$model" = "gpt-4o" ]; then
    input_price=$rg_GPT4O_INPUT_PRICE
    output_price=$rg_GPT4O_OUTPUT_PRICE
  else
    # Default to GPT-4.1 mini pricing if model is unknown
    input_price=$rg_GPT41MINI_INPUT_PRICE
    output_price=$rg_GPT41MINI_OUTPUT_PRICE
  fi
  
  # Calculate cost PER MILLION tokens (not per thousand)
  local input_cost=$(echo "scale=10; ($prompt_tokens * $input_price) / 1000000" | bc -l)
  local output_cost=$(echo "scale=10; ($completion_tokens * $output_price) / 1000000" | bc -l)
  local request_cost=$(echo "scale=10; $input_cost + $output_cost" | bc -l)
  
  # Update total cost
  file_cost=$(echo "scale=10; $file_cost + $request_cost" | bc -l)
  export rg_TOTAL_COST=$file_cost
  
  # Save updated values to file
  echo "$file_input_tokens $file_output_tokens $file_cost" > "$TOKEN_FILE"
  
  echo "$response"
}

# Parse regular response
parse_api_response() {
  local response="$1"
  
  # Create a temporary Python script to parse the response
  local tmp_parse_script=$(mktemp)
  cat > "$tmp_parse_script" << 'EOPY'
import sys, json

# Read input from stdin
data = json.load(sys.stdin)

if 'error' in data:
    print('Error:', data['error']['message'])
else:
    print(data['choices'][0]['message']['content'])
EOPY

  # Parse response 
  local text
  text=$(python3 "$tmp_parse_script" <<< "$response")
  
  # Clean up temporary file
  rm -f "$tmp_parse_script"

  echo "$text"
}

# Parse suggestion response
parse_suggestion_response() {
  local response="$1"
  
  # Create a temporary Python script to parse and clean the response
  local tmp_parse_script=$(mktemp)
  cat > "$tmp_parse_script" << 'EOPY'
import sys, json

# Read input from stdin
data = json.load(sys.stdin)

if 'error' in data:
    print('Error:', data['error']['message'])
else:
    text = data['choices'][0]['message']['content']
    # Clean up any remaining formatting issues
    text = text.replace('```', '').strip()
    print(text)
EOPY

  # Parse response and clean it up
  local text
  text=$(python3 "$tmp_parse_script" <<< "$response")
  
  # Clean up temporary file
  rm -f "$tmp_parse_script"

  echo "$text"
}

# Display usage summary
display_usage_summary() {
  # Ensure we have the latest token values from file
  TOKEN_FILE="/tmp/reportgen_token_counters.txt"
  if [[ -f "$TOKEN_FILE" ]]; then
    read -r file_input_tokens file_output_tokens file_cost < "$TOKEN_FILE"
    
    # Ensure values are numbers
    [[ "$file_input_tokens" =~ ^[0-9]+$ ]] || file_input_tokens=0
    [[ "$file_output_tokens" =~ ^[0-9]+$ ]] || file_output_tokens=0
    [[ "$file_cost" =~ ^[0-9.]+$ ]] || file_cost=0
    
    # Update global variables
    export rg_TOTAL_INPUT_TOKENS=$file_input_tokens
    export rg_TOTAL_OUTPUT_TOKENS=$file_output_tokens
    export rg_TOTAL_COST=$file_cost
  fi

  # Display token usage and cost information
  echo -e "\n===== USAGE SUMMARY ====="
  echo "Input tokens: $rg_TOTAL_INPUT_TOKENS"
  echo "Output tokens: $rg_TOTAL_OUTPUT_TOKENS"
  echo "Total tokens: $((rg_TOTAL_INPUT_TOKENS + rg_TOTAL_OUTPUT_TOKENS))"

  # Format cost with simple rounding to show appropriate significant digits
  format_cost
  
  echo "Cost: $rg_formatted_cost USD"
  echo "Model used: $DEFAULT_MODEL"
}

# Format the cost for display
format_cost() {
  # For zero cost, just show $0.00
  if (( $(echo "$rg_TOTAL_COST == 0" | bc -l) )); then
    rg_formatted_cost="\$0.00"
    return
  fi
  
  # Use a simpler approach for small numbers
  if (( $(echo "$rg_TOTAL_COST < 0.01" | bc -l) )); then
    # For very small costs (less than a cent), show 5 decimal places
    rg_formatted_cost=$(printf "\$%.5f" "$rg_TOTAL_COST")
  else
    # For larger costs, show 2 decimal places
    rg_formatted_cost=$(printf "\$%.2f" "$rg_TOTAL_COST")
  fi
} 