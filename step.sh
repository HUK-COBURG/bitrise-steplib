#!/bin/bash
set -ex

cmd="cdxgen"

if [ -n "$type" ]; then
  cmd="$cmd -t $type"
fi

if [ -n "$specversion" ]; then
  cmd="$cmd --spec-version $specversion"
fi

if [ -n "$output" ]; then
  cmd="$cmd -o $output"
fi

eval $cmd
