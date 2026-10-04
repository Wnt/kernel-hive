10 rem double helix
20 print chr$(147);:for i=1 to 6:d$=d$+"==========":next
30 for i=0 to 21
40 a=38+int(30*sin(i/2.4)):b=77-a:l$="O":r$="*"
50 if a>b then t=a:a=b:b=t:l$="*":r$="O"
60 print tab(a);l$;left$(d$,b-a-1);r$
70 next i
