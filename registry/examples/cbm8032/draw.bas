10 rem bar chart
20 print chr$(147);"Units sold per month":print
30 for m=1 to 12:read n$,v:print n$;" ";chr$(18);
40 for i=1 to v/2:print " ";:next
50 print chr$(146);v:next m
60 data "Jan",64,"Feb",58,"Mar",72,"Apr",80,"May",95,"Jun",103
70 data "Jul",118,"Aug",112,"Sep",91,"Oct",84,"Nov",77,"Dec",99
