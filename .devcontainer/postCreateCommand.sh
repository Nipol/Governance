#!/usr/bin/env zsh

set -e

sudo chown node node_modules \
     && foundryup \
     && npm install
