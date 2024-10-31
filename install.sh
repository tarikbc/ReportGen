#!/bin/bash

# Define the path to the index.sh script
SCRIPT_PATH="$(pwd)/index.sh"

# Define the target path for the symbolic link
TARGET_PATH="/usr/local/bin/reportgen"

# Check if the script exists
if [ ! -f "$SCRIPT_PATH" ]; then
  echo "Error: index.sh not found in the current directory."
  exit 1
fi

# Create a symbolic link
sudo ln -sf "$SCRIPT_PATH" "$TARGET_PATH"

# Make the script executable
chmod +x "$SCRIPT_PATH"

echo "Installation complete. You can now run 'reportgen' from anywhere."