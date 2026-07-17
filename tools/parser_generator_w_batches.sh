#!/bin/sh
# Run bin/parser_generator_w_test over every tracked .w file in
# batches of one process each. The binary's manifest test retains the
# AST of every file it parses; one process over the whole repo blows
# the 32-bit address-space ceiling once tracked source passes a few
# MB, and freeing per file instead crawls the first-fit allocator
# quadratically (2026-07-12, docs/projects/ai_tooling_next_steps.md).
# Restarting the process per batch bounds memory at batch size
# forever, whatever the repo grows to.
#
# Expects bin/parser_generator_w_files.txt (the full git ls-files
# list) and the built test binary; reruns the binary once per
# 150-file slice with the manifest path swapped to that slice.
set -e

full=bin/parser_generator_w_full_list.txt
slice=bin/parser_generator_w_files.txt
batch=150

# The manifest step wrote the full list to the canonical path; move it
# aside so slices can take its place.
cp "$slice" "$full"
total=$(wc -l < "$full")
i=0
while [ $((i * batch)) -lt "$total" ]; do
	start=$((i * batch + 1))
	end=$(((i + 1) * batch))
	sed -n "${start},${end}p" "$full" > "$slice"
	bin/parser_generator_w_test
	i=$((i + 1))
done
# Restore the full list so reruns and other tooling see it intact.
cp "$full" "$slice"
