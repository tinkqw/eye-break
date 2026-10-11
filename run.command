#!/bin/bash
cd "$(dirname "$0")"
swift build 2>&1 && .build/debug/EyeBreak
