NEW
10 REMark Mirror writer
20 MODE 4:WINDOW 512,200,0,0:PAPER 0:INK 4:CLS
30 INPUT "Type a word: ";w$
40 r$=""
50 FOR i=LEN(w$) TO 1 STEP -1:r$=r$&w$(i)
60 PRINT "Backwards it reads: ";r$
70 IF r$==w$ THEN PRINT "It is a palindrome!"
