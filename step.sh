#!/usr/bin/env bash

FULL_PATH=$(printf "%s" "$repository_url" \
  | sed -E -e 's#^https?://[^/]+/##' -e 's#^git@[^:]+:##' -e 's#\.git$##')

PROJECT_ID=${FULL_PATH//\//%2F}

# 1) Get the time stamp of the target commit
commit_date=$(
  curl -k -sS -H "PRIVATE-TOKEN: $gitlab_token" \
    "$gitlab_base_url/projects/$PROJECT_ID/repository/commits/$commit_hash" \
  | jq -re '.committed_date' 2>/dev/null || true
)

if [[ -z "$commit_date" || "$commit_date" == "null" ]]; then
  echo "Error: Commit $commit_hash not found or no date found." >&2
  exit 1
fi

# 2) Count the commit with pagination
declare -i count=0
url="$gitlab_base_url/projects/$PROJECT_ID/repository/commits?per_page=100&until=$commit_date"

while :; do
  # Get body and header
  response=$(curl -k -sS -i -H "PRIVATE-TOKEN: $gitlab_token" "$url")

  # Split body and header
  sep=$'\r\n\r\n'
  if [[ "$response" == *"$sep"* ]]; then
    headers="${response%%$sep*}"
    body="${response#*$sep}"
  else
    # Fallback if just \n is used
    sep=$'\n\n'
    headers="${response%%$sep*}"
    body="${response#*$sep}"
  fi

  # Check HTTP status
  http_code=$(printf "%s" "$headers" | awk '/^HTTP/{code=$2} END{print code}')
  if [[ "$http_code" != "200" ]]; then
    echo "Error: HTTP $http_code at $url" >&2
    printf "%s\n" "$headers" | sed -n '1,20p' >&2
    exit 1
  fi

  # Count items on the current page
  page_count=$(printf "%s" "$body" | jq -r 'length' 2>/dev/null)
  if ! [[ "$page_count" =~ ^[0-9]+$ ]]; then
    echo "Error: Response is not a valid JSON at $url." >&2
    exit 1
  fi
  count=$(( count + page_count ))

  # Get next page from Link header (rel="next")
  link_line=$(printf "%s" "$headers" | tr -d '\r' | grep -i '^Link:' || true)
  next=$(printf "%s" "$link_line" \
    | grep -o '<[^>]*>; rel="next"' \
    | sed -E 's/^<([^>]*)>;.*$/\1/' \
    | head -n1)

  [[ -z "$next" ]] && break
  url="$next"
done

echo "Determined $count commits. Setting as bundle version."

envman add --key "BUNDLE_VERSION" --value $count
