#!/bin/bash

# Check for required arguments
if [ $# -ne 2 ]; then
  echo "Usage: $0 <local_folder> <s3_prefix>"
  exit 1
fi

local_folder=$1
s3_prefix=$2

# Ensure trailing slash for S3 prefix
if [[ ! $s3_prefix =~ "/"$ ]]; then
  s3_prefix="${s3_prefix}/"
fi

# Iterate through files in the local folder
for file in "$local_folder"/*; do
  if [ -f "$file" ]; then
    s3_key="${s3_prefix}${file##*/}"
    aws s3 cp "$file" s3://trimm-archi-upload/"$s3_key"
  fi
done
