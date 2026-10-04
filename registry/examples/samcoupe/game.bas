10 REM Higher or lower
20 MODE 3: CLS: RANDOMIZE: LET s=0: LET c=1+RND(12)
30 PRINT "Card ";c;". Is the next higher or lower (h/l): ";
40 GET k$: PRINT k$: LET d=1+RND(12)
50 LET w=SGN (d-c)
60 IF k$="l" OR k$="L" THEN LET w=-w
70 PRINT "Next card: ";d
80 IF w=-1 THEN PRINT "Wrong! Score ";s;" - RUN again": STOP
90 LET s=s+1: LET c=d: GO TO 30
