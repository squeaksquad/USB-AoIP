usb16x16-dsp 1
preset pinned monitor vector
rate 48000
channels 16
internal 2
maxdelay 480
expand 2
0 0 0.125
1 1 -0.5
branch 1
1 2
1 0 0 0 0
0.5 0.25 0 -0.1 0.01
assign 2
0 0 1
3 1 0
output 16
0 48 0.5 1
1 0 0 0 0
1 0 1 0
2 0 1 0
3 0 1 0
4 0 1 0
5 0 1 0
6 0 1 0
7 0 1 0
8 0 1 0
9 0 1 0
10 0 1 0
11 0 1 0
12 0 1 0
13 0 1 0
14 0 1 0
15 0 1 0
monitor 1
sets 2
set front speakers
set cans headphones
outs 3
out 0 speaker 0
out 3 sub 0
out 5 speaker 1
label 0 Left  main
label 3 Sub
expandsets 2
0
-
folds 2
fold 0 stereo 2
0 0 1
0 2 0.7071067811865476
fold 0 mono 3
0 0 0.5
0 1 0.5
3 3 1
end
