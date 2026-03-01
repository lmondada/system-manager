#!/usr/bin/env bash

nix run 'github:numtide/system-manager' -- switch --sudo --flake .
