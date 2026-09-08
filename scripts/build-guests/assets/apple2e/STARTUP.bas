10  HOME 
20  PRINT "  ============================================"
30  PRINT "     APPLE //e  --  PRODOS  MENU"
40  PRINT "  ============================================"
50  PRINT
60  PRINT "    [1]  AppleWorks 3.0"
70  PRINT "    [2]  Dazzle Draw 1.2"
80  PRINT "    [3]  Angry Birds  (not staged yet)"
90  PRINT "    [B]  BASIC prompt  (type RUN STARTUP to return)"
100  PRINT
110  PRINT "  ============================================"
120  PRINT "   RESET always returns to this menu."
130  PRINT "  ============================================"
140  PRINT
150  PRINT "  CHOOSE 1, 2, 3 OR B: ";
160  GET K$
170  IF K$ = "1" THEN  GOTO 300
180  IF K$ = "2" THEN  GOTO 400
190  IF K$ = "3" THEN  GOTO 500
200  IF K$ = "B" OR K$ = "b" THEN  GOTO 600
210  GOTO 150
300  PRINT K$
310  PRINT CHR$ (4);"PREFIX /HIVE/AW"
320  PRINT CHR$ (4);"-APLWORKS.SYSTEM"
330  GOTO 150
400  PRINT K$
410  PRINT CHR$ (4);"PREFIX /HIVE/DAZZLE"
420  PRINT CHR$ (4);"-DD.SYSTEM"
430  GOTO 150
500  PRINT K$
510  HOME 
520  PRINT "ANGRY BIRDS IS NOT ON THIS VOLUME YET."
530  PRINT "8-BIT SHACK'S FREE DOWNLOAD WENT DOWN;"
540  PRINT "SEE THE STATION'S RELEASE NOTES."
550  PRINT
560  PRINT "PRESS ANY KEY TO RETURN.";
570  GET K$
580  GOTO 150
600  PRINT K$
610  HOME 
620  PRINT "BASIC PROMPT.  TYPE RUN STARTUP TO RETURN."
630  END
