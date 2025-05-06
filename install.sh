#!/bin/bash

# Define the path to the index.sh script
SCRIPT_PATH="$(pwd)/index.sh"
LIB_PATH="$(pwd)/lib"

# Define the target path for the symbolic link
TARGET_PATH="/usr/local/bin/reportgen"

# Check if the script exists
if [ ! -f "$SCRIPT_PATH" ]; then
  echo "Error: index.sh not found in the current directory."
  exit 1
fi

# Check if lib directory exists
if [ ! -d "$LIB_PATH" ]; then
  echo "Error: lib directory not found in the current directory."
  exit 1
fi

# Create a symbolic link
sudo ln -sf "$SCRIPT_PATH" "$TARGET_PATH"

# Make the scripts executable
chmod +x "$SCRIPT_PATH" 
chmod +x "$LIB_PATH"/*.sh

echo "Installation complete. You can now run 'reportgen' from anywhere."