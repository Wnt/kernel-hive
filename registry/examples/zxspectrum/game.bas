10 RANDOMIZE: LET b=14: LET s=0
20 LET x=INT (RND*30): FOR y=1 TO 20
30 PRINT AT y,x;"o": LET b=b+(INKEY$="p" AND b<28)-(INKEY$="o" AND b>0)
40 PRINT AT 21,b;" == ";AT y,x;" "
50 NEXT y: IF ABS (x-b-1)<2 THEN LET s=s+1: BEEP .05,24
60 PRINT AT 0,0;"Score ";s: GO TO 20
