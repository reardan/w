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
#
# On failure, a batch's stack trace used to drown in the other
# batches' "passed!" banners with nothing naming the culprit
# (2026-07-28, docs/projects/ai_tooling_next_steps.md): now the runner
# prints "batch N (files X..Y of TOTAL) FAILED" with the line range
# into the full list, then reruns that batch one file per process to
# name the offending file(s) directly.
set -e

full=bin/parser_generator_w_full_list.txt
slice=bin/parser_generator_w_files.txt
failed=bin/parser_generator_w_failed_batch.txt
batch=150

# The manifest step wrote the full list to the canonical path; move it
# aside so slices can take its place.
cp "$slice" "$full"
total=$(wc -l < "$full")
i=0
while [ $((i * batch)) -lt "$total" ]; do
	start=$((i * batch + 1))
	end=$(((i + 1) * batch))
	if [ "$end" -gt "$total" ]; then
		end=$total
	fi
	sed -n "${start},${end}p" "$full" > "$slice"
	if ! bin/parser_generator_w_test; then
		echo "parser_generator_w_batches: batch $((i + 1)) (files ${start}..${end} of ${total}) FAILED" >&2
		# Isolate the culprit: rerun this batch's files one per
		# process. A parse failure is per-file, so the file that fails
		# alone is the one that failed the batch.
		cp "$slice" "$failed"
		culprits=0
		while IFS= read -r file; do
			printf '%s\n' "$file" > "$slice"
			if ! bin/parser_generator_w_test >/dev/null 2>&1; then
				echo "parser_generator_w_batches: offending file: $file" >&2
				culprits=$((culprits + 1))
			fi
		done < "$failed"
		if [ "$culprits" -eq 0 ]; then
			echo "parser_generator_w_batches: no single file of the batch fails alone (batch list kept in $failed)" >&2
		fi
		cp "$full" "$slice"
		exit 1
	fi
	i=$((i + 1))
done
# Restore the full list so reruns and other tooling see it intact.
cp "$full" "$slice"
