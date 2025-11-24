#!/usr/bin/env bash
#
# Get the commit count (sequence number) for a given commit hash from a GitLab project
# using the "Get commit sequence" GitLab API.
#
# Works on macOS and Ubuntu. Requires only: curl, sed/awk/grep (standard).
# Comments and messages are in English as requested.
#
# Inputs (provide via environment variables or as CLI arguments in this order):
#   1) repository_url   (e.g., "https://gitlab.com/group/project.git" or "git@gitlab.com:group/project.git")
#   2) gitlab_base_url  (e.g., "https://gitlab.com" or "https://gitlab.yourcompany.com")
#   3) gitlab_token     (Personal Access Token or Job Token with API scope)
#   4) commit_hash      (the commit SHA to query)
#   5) variable_name    (name of the variable to export/print with the count)
#
# Output:
#   - Exports an environment variable named $variable_name with the commit count (for the current process).
#   - Prints a line "variable_name=COUNT" to stdout, suitable for consumption by CI or other scripts.
#
# Note:
#   - The script derives the GitLab project path (namespace/project) from repository_url.
#   - The GitLab API expects URL-encoding of the project path (replace "/" with "%2F").
#   - If your GitLab instance requires a different auth header (e.g., "JOB-TOKEN"), adjust AUTH_HEADER below.
#
# Example:
#   export repository_url="https://gitlab.com/gitlab-org/gitlab.git"
#   export gitlab_base_url="https://gitlab.com"
#   export gitlab_token="glpat-xxxxxxxx"
#   export commit_hash="abcdef1234567890"
#   export variable_name="COMMIT_COUNT"
#   ./get_commit_count.sh
#
# Or via CLI args:
#   ./get_commit_count.sh "https://gitlab.com/group/project.git" "https://gitlab.com" "glpat-xxxx" "abcdef..." "COMMIT_COUNT"
#

set -euo pipefail

# Basic validation
err() { printf 'Error: %s\n' "$*" >&2; }
need() { [ -n "${!1:-}" ] || { err "Missing required input: $1"; exit 1; }; }

need repository_url
need gitlab_base_url
need gitlab_token
need commit_hash
need variable_name

# Normalize base URL (remove trailing slash)
gitlab_base_url="${gitlab_base_url%/}"

# Extract project path "group/subgroup/project" from repository_url
# Supports HTTPS and SSH forms:
#   - https://gitlab.com/group/project.git
#   - https://gitlab.example.com/group/subgroup/project
#   - git@gitlab.com:group/project.git
#   - ssh://git@gitlab.example.com/group/project.git
#
# We will:
#   1) Remove protocol and host.
#   2) Remove leading ":" or "/" if present.
#   3) Strip trailing ".git".
project_path=""
case "$repository_url" in
  http://*|https://*)
    # Remove scheme and host
    # Example: https://gitlab.com/group/project.git -> group/project.git
    project_path="$(printf '%s\n' "$repository_url" \
      | sed -E 's@^https?://[^/]+/@@')"
    ;;
  ssh://*)
    # Example: ssh://git@gitlab.example.com/group/project.git -> group/project.git
    project_path="$(printf '%s\n' "$repository_url" \
      | sed -E 's@^ssh://[^/]+/@@')"
    ;;
  git@*:* )
    # Example: git@gitlab.com:group/project.git -> group/project.git
    project_path="$(printf '%s\n' "$repository_url" \
      | sed -E 's@^[^:]+:@@')"
    ;;
  *)
    err "Unrecognized repository_url format: $repository_url"
    exit 1
    ;;
esac

# Remove leading slashes/colons if any and trailing .git
project_path="$(printf '%s\n' "$project_path" | sed -E 's@^[/:]+@@; s@\.git$@@')"

if [ -z "$project_path" ]; then
  err "Could not parse project path from repository_url"
  exit 1
fi

# URL-encode "/" as "%2F" for GitLab API project identifier
# Note: We assume project_path contains only URL-safe chars aside from "/".
project_id_enc="$(printf '%s' "$project_path" | sed 's@/@%2F@g')"

# Prepare auth header (adjust if using JOB-TOKEN in CI)
AUTH_HEADER="PRIVATE-TOKEN: $gitlab_token"

# Endpoint:
# According to GitLab API "Get commit sequence", the commit count (sequence number)
# is available via the commit details endpoint.
# Path: /api/v4/projects/:id/repository/commits/:sha/sequence
commit_url="${gitlab_base_url}/api/v4/projects/${project_id_enc}/repository/commits/${commit_hash}/sequence"

# Perform the request
response="$(curl -k -sS -H "$AUTH_HEADER" "$commit_url")" || {
  err "Failed to call GitLab API"
  exit 1
}

# Basic error detection: if response contains "message" error or is empty
if [ -z "$response" ]; then
  err "Empty response from GitLab API"
  exit 1
fi

# Try to detect common API error shape: {"message":"..."}
if printf '%s' "$response" | grep -q '"message"'; then
  err "GitLab API error: $(printf '%s' "$response" | sed -E 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/;t; s/.*/Unknown error/')"
  exit 1
fi

# Extract commit count. GitLab returns a field named "commit_count" for the sequence number.
# Fall back to alternative keys if present ("commits_count" or "count") to be robust.
commit_count="$(printf '%s' "$response" | grep -Eo '"count"[[:space:]]*:[[:space:]]*[0-9]+' | grep -Eo '[0-9]+' || true)"

if [ -z "$commit_count" ]; then
  err "Could not find commit count in API response. Raw response:"
  printf '%s\n' "$response" >&2
  exit 1
fi

echo "Determined $commit_count commits. Setting as bundle version ($variable_name)."

envman add --key "$variable_name" --value $commit_count
