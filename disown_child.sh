#!/bin/bash

THISDIR=$(dirname $(readlink -f $0))
$THISDIR/$1 </dev/null &
disown
