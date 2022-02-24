#!/bin/bash
today=`date '+%d_%m_%y_%H_%M_%S'`;
filename="./old/cc500_$today";
cp cc500 $filename;
echo "Backed up to $filename";