#!/bin/sh
clear
odin build . -show-timings -use-separate-modules -o:none &&
    ./mkheaders copypasta
