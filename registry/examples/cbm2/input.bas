10 rem day of the week
20 print chr$(147);"Which day of the week? (year 0 stops)"
30 print:input "Year";y:if y=0 then end
40 input "Month (1-12)";m:input "Day (1-31)";d
50 if m<3 then m=m+12:y=y-1
60 k=y-int(y/100)*100:j=int(y/100)
70 h=d+int(13*(m+1)/5)+k+int(k/4)+int(j/4)+5*j
80 h=h-int(h/7)*7:restore:for i=0 to h:read w$:next
90 print "That day is a ";w$;"."
100 goto 30
110 data "Saturday","Sunday","Monday","Tuesday"
120 data "Wednesday","Thursday","Friday"
