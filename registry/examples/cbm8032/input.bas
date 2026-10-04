10 rem savings plan
20 print chr$(147);"Savings plan":print
30 input "Amount saved each year";a
40 input "Interest rate in percent";r
50 input "Number of years";n
60 print:print "Year","Paid in","Balance":b=0
70 for y=1 to n:b=(b+a)*(1+r/100)
80 print y,y*a,int(b*100+.5)/100:next y
