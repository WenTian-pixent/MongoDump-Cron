#!/bin/bash

# Check if at least one filename argument is provided
if [ "$#" -lt 1 ]; then
  echo "Please provide the filename as an argument."
  exit 1
fi

message=""
errorMessage=""

for file in "$@"; do
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "Error reading file: $file"
    exit 1
  fi

  fileContent=$(<"$file")
  # Create message without \n & empty spaces/tabs, jq will format it correctly
  if [[ "$fileContent" == *"done dumping"* ]]; then
    message+=":white_check_mark: ## MongoDump ran successfully!
**Filename:** $file
**Content:**
\`\`\`$fileContent\`\`\`
"
  else
    errorMessage+=":x: ## MongoDump ran failed!
**Filename:** $file
**Content:**
\`\`\`$fileContent\`\`\`
"
  fi
done

call_discord_webhook() {
    payload=$(jq -n --arg content "$1" '{ content: $content }')
    curl -H "Content-Type: application/json" \
     -X POST \
     -d "$payload" \
     "$2"
}

if [ -n "$message" ]; then
  call_discord_webhook "$message" "$DISCORD_CHANNEL_SUCCESS"
fi

if [ -n "$errorMessage" ]; then
  call_discord_webhook "$errorMessage" "$DISCORD_CHANNEL_FAILED"
fi