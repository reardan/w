#!/bin/bash
# Back up a committed seed binary to ./old/ with a timestamp before a
# promotion overwrites it. Defaults to the Linux seed; 'update_darwin'
# passes w_darwin.
seed="${1:-w}";
today=`date '+%d_%m_%y_%H_%M_%S'`;
filename="./old/${seed}_$today";
mkdir -p ./old;
cp "./$seed" "$filename";
echo "Backed up to $filename";
