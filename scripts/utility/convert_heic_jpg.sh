#!/bin/bash

target_dir="$1"

if [ ! -d "$target_dir" ]; then
    echo "Error: Directory '$target_dir' does not exist."
    exit 1
fi

shopt -s nocaseglob
for file in "$target_dir"/*.heic; do
  fileNoExt="${file%.*}"
  jpgFile="${fileNoExt}.jpg"

    sips -s format jpeg -s formatOptions best "$file" --out "$jpgFile"

    if [ -f "$jpgFile" ]; then
        cp -p "$file" "$jpgFile"
        rm "$file"
    fi
done
