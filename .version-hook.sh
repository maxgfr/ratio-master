#!/bin/bash

# Semantic Release Hook - Update version in ratio-master.sh
# This script is called by semantic-release to update the VERSION in ratio-master.sh

if [ -z "$1" ]; then
  echo "Error: Version number required"
  exit 1
fi

NEW_VERSION="$1"

# Update VERSION in ratio-master.sh
sed -i.bak "s/^readonly VERSION=\".*\"/readonly VERSION=\"$NEW_VERSION\"/" ratio-master.sh && rm ratio-master.sh.bak

echo "Updated ratio-master.sh to version $NEW_VERSION"
