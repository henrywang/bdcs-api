#!/bin/bash

STORE=$(realpath /mddb/"${STORE:-cs.repo}")
MDDB="/mddb/${MDDB:-metadata.db}"
RECIPES="${RECIPES:-/recipes/}"

mkdir -p /run/weldr
/usr/local/bin/bdcs-api-server -s /run/weldr/api.socket -g root --bdcs "$STORE" "$MDDB" "$RECIPES"
