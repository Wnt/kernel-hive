10 rem reaction timer
20 x=rnd(-ti):b=99:print chr$(147);"Reaction timer"
30 print "Press any key the moment you see NOW!"
40 for r=1 to 5:print:print "Round";r;"- wait for it...";
50 w=ti+60+int(rnd(1)*180)
60 get k$:if k$<>"" then print " too early!";:goto 50
70 if ti<w then 60
80 print " NOW!";:t=ti
90 get k$:if k$="" then 90
100 t=int((ti-t)/.6)/100:print t;"seconds":if t<b then b=t
110 next r
120 print:print "Best of five:";b;"seconds"
130 input "Play again (y/n)";a$:if a$="y" then 20
