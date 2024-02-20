#!/bin/bash
set -ex

cmd="license-plist"

if [ -n "$github_token" ]; then
  cmd="$cmd --github-token $github_token"
fi

eval $cmd
