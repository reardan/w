#!/bin/bash
today=`date '+%d_%m_%y_%H_%M_%S'`;
filename="./old/w_$today";
cp w $filename;
echo "Backed up to $filename";