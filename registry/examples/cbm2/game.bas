10 rem the last match
20 x=rnd(-rnd(0)):n=15+int(rnd(1)*10)
30 print chr$(147);"Take 1, 2 or 3 matches each turn."
40 print "Whoever takes the last match loses."
50 print:print n;"matches  ";:for i=1 to n:print "! ";:next:print
60 input "How many do you take";t:t=int(t)
70 if t<1 or t>3 or t>n then print "1, 2 or 3, please.":goto 60
80 n=n-t:if n=0 then print "You took the last match - I win!":goto 130
90 c=n-1-int((n-1)/4)*4:if c=0 then c=1
100 print "I take";c:n=n-c
110 if n=0 then print "I took the last match - you win!":goto 130
120 goto 50
130 print:input "Play again (y/n)";a$:if a$="y" then 20
