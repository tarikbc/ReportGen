#!/bin/bash

# Functions for interacting with OpenAI APIs

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
    '{
      "model": "gpt-4o",
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
  
  echo "Generating commit message and branch name based on the changes..."
  
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
    '{
      "model": "gpt-4o",
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
  
  rg_TOTAL_INPUT_TOKENS=$((rg_TOTAL_INPUT_TOKENS + prompt_tokens))
  rg_TOTAL_OUTPUT_TOKENS=$((rg_TOTAL_OUTPUT_TOKENS + completion_tokens))
  
  # Calculate cost for this request
  local input_cost=$(echo "$prompt_tokens * $rg_GPT4O_INPUT_PRICE / 1000" | bc -l)
  local output_cost=$(echo "$completion_tokens * $rg_GPT4O_OUTPUT_PRICE / 1000" | bc -l)
  local request_cost=$(echo "$input_cost + $output_cost" | bc -l)
  rg_TOTAL_COST=$(echo "$rg_TOTAL_COST + $request_cost" | bc -l)
  
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
  # Display token usage and cost information
  echo -e "\n===== USAGE SUMMARY ====="
  echo "Input tokens: $rg_TOTAL_INPUT_TOKENS"
  echo "Output tokens: $rg_TOTAL_OUTPUT_TOKENS"
  echo "Total tokens: $((rg_TOTAL_INPUT_TOKENS + rg_TOTAL_OUTPUT_TOKENS))"

  # Calculate total cost in a way that preserves precision
  local input_cost=$(echo "scale=10; $rg_TOTAL_INPUT_TOKENS * $rg_GPT4O_INPUT_PRICE / 1000" | bc)
  local output_cost=$(echo "scale=10; $rg_TOTAL_OUTPUT_TOKENS * $rg_GPT4O_OUTPUT_PRICE / 1000" | bc)
  rg_TOTAL_COST=$(echo "scale=10; $input_cost + $output_cost" | bc)

  # Format cost with simple rounding to show appropriate significant digits
  format_cost
  
  echo "Cost: $rg_formatted_cost USD"
}

# Format the cost for display
format_cost() {
  if (( $(echo "$rg_TOTAL_COST == 0" | bc -l) )); then
    rg_formatted_cost="$0.00"
  elif (( $(echo "$rg_TOTAL_COST >= 0.01" | bc -l) )); then
    # For costs >= $0.01, show 2 decimal places
    rg_formatted_cost=$(printf "$%.2f" "$rg_TOTAL_COST")
  elif (( $(echo "$rg_TOTAL_COST >= 0.001" | bc -l) )); then
    # For costs >= $0.001, show 3 decimal places
    rg_formatted_cost=$(printf "$%.3f" "$rg_TOTAL_COST")
  elif (( $(echo "$rg_TOTAL_COST >= 0.0001" | bc -l) )); then
    # For costs >= $0.0001, show 4 decimal places
    rg_formatted_cost=$(printf "$%.4f" "$rg_TOTAL_COST")
  else
    # For very small costs, round to 5 significant digits
    # First convert to scientific notation
    local sci_notation=$(printf "%.10e" "$rg_TOTAL_COST")
    
    # Extract mantissa and exponent
    local mantissa=$(echo "$sci_notation" | sed -E 's/([0-9]+\.[0-9]+)e.*/\1/')
    local exponent=$(echo "$sci_notation" | sed -E 's/.*e-?([0-9]+)/\1/')
    local sign=$(echo "$sci_notation" | grep -o 'e-' || echo "e+")
    
    if [ "$sign" = "e-" ]; then
      # For negative exponents, show rounded decimal
      local rounded_mantissa=$(printf "%.5g" "$mantissa" | sed 's/\.0*$//')
      local rounded_cost=$(echo "scale=10; $rounded_mantissa * 10^-$exponent" | bc -l)
      
      # Determine decimal places needed (exponent + 1 to show first significant digit)
      local decimal_places=$((exponent + 1))
      if [ "$decimal_places" -gt 10 ]; then
        decimal_places=10  # Cap at 10 decimal places for readability
      fi
      
      # Format with appropriate number of decimal places
      rg_formatted_cost=$(printf "$%.*f" "$decimal_places" "$rounded_cost")
      
      # Trim trailing zeros
      rg_formatted_cost=$(echo "$rg_formatted_cost" | sed 's/\.0*$//' | sed 's/\.\([0-9]*[1-9]\)0*$/.\1/')
      
      # Ensure we have at least 1 decimal place for small numbers
      if [[ ! "$rg_formatted_cost" =~ \. ]]; then
        rg_formatted_cost="$rg_formatted_cost.0"
      fi
    else
      # For positive exponents, use standard format
      rg_formatted_cost=$(printf "$%.2f" "$rg_TOTAL_COST")
    fi
  fi
} 