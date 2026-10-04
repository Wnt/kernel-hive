10 REM Circle maker
20 MODE 4: PAPER 0: CLS
30 INPUT "Radius 1-80 (0 to stop): ";r
40 IF r=0 THEN STOP
50 PEN 1+RND(14): CIRCLE 128,88,r
60 PRINT AT 0,0;"Area: ";INT (PI*r*r);"    "
70 GO TO 30
