10 REMark Guess my number
20 MODE 4:WINDOW 512,200,0,0:PAPER 0:INK 7:CLS
30 RANDOMISE:n=RND(1 TO 100):t=0
40 PRINT "I am thinking of a number, 1 to 100."
50 REPeat guess
60 INPUT "Your guess: ";g:t=t+1
70 IF g=n THEN EXIT guess
80 IF g<n THEN PRINT "Higher!":ELSE PRINT "Lower!"
90 END REPeat guess
100 PRINT "Yes, ";n;"! You took ";t;" goes."
110 PRINT "Type RUN to play again."
