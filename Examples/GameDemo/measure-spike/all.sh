#!/bin/bash
# The whole queue, strictly sequential: fold, arms, cow.
source "$(dirname "$0")/lib.sh"
mkdir -p $R
{ $S/fold.sh && $S/arms.sh && $S/cow.sh; } 2>&1 | tee -a $R/all.log
