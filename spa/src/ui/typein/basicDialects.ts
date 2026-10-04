import type { BasicDialect } from '../../types';

// ---------------------------------------------------------------------------
//  basicDialects — just enough of each BASIC for a highlighter to be useful.
//
//  NOT a parser and NOT a tokeniser of record: the machine decides what is a
//  keyword, and the editor only paints a guess. One shared core of Microsoft
//  BASIC words, plus each dialect's own. Lists are upper case; matching is
//  case-insensitive because the station's case rule (registry `typeIn.case`)
//  decides what actually reaches the guest.
//
//  `crunched`: the interpreter finds keywords INSIDE unspaced text
//  (`FORI=1TO10`), so the highlighter does too, longest keyword first — which
//  is also why `TOTAL` lights up `TO` on a Commodore: the machine reads it that
//  way. Dialects that need spaces between words match whole words only.
// ---------------------------------------------------------------------------

export interface DialectSpec {
  readonly name: string;
  readonly keywords: ReadonlySet<string>;
  /** Keywords longest first, for the crunched scan. */
  readonly byLength: readonly string[];
  readonly crunched: boolean;
  /** `'` starts a comment, as in MSX-BASIC and Locomotive BASIC. */
  readonly apostropheComment: boolean;
  /** `?` is shorthand for PRINT. */
  readonly questionPrint: boolean;
  /** Magazine listings write control keys as `{CLR}`, `{DOWN}` (Commodore). */
  readonly braceTokens: boolean;
}

const MS_CORE =
  'END FOR NEXT DATA INPUT DIM READ LET GOTO GOSUB RUN IF RESTORE RETURN REM STOP ON WAIT LOAD SAVE DEF ' +
  'POKE PRINT CONT LIST CLEAR NEW TAB TO FN SPC THEN NOT STEP AND OR SGN INT ABS USR FRE POS SQR RND LOG ' +
  'EXP COS SIN TAN ATN PEEK LEN STR$ VAL ASC CHR$ LEFT$ RIGHT$ MID$ GET';

const WORDS: Record<BasicDialect, { name: string; words: string; crunched: boolean; apostrophe?: boolean; question?: boolean; braces?: boolean }> = {
  'cbm-basic': {
    name: 'Commodore BASIC',
    crunched: true, question: true, braces: true,
    words: `${MS_CORE} CLR CMD SYS OPEN CLOSE VERIFY GO CONCAT DOPEN DCLOSE RECORD HEADER COLLECT BACKUP ` +
      'COPY APPEND DSAVE DLOAD CATALOG RENAME SCRATCH DIRECTORY RGR RCLR JOY RDOT DEC HEX$ ERR$ INSTR ELSE ' +
      'RESUME TRAP TRON TROFF SOUND VOL AUTO GRAPHIC PAINT CHAR BOX CIRCLE DRAW LOCATE COLOR SCNCLR SCALE ' +
      'DO LOOP EXIT UNTIL WHILE DELETE RENUMBER KEY MONITOR USING BANK PLAY TEMPO SPRITE SLEEP FAST SLOW',
  },
  'bbc-basic': {
    name: 'BBC BASIC',
    crunched: true,
    words: 'ABS ACS ADVAL AND ASC ASN ATN AUTO BGET BPUT CALL CHAIN CHR$ CLEAR CLG CLOSE CLS COLOUR COS COUNT ' +
      'DATA DEF DEG DELETE DIM DIV DRAW ELSE END ENDPROC ENVELOPE EOF EOR ERL ERR ERROR EVAL EXP EXT FALSE ' +
      'FN FOR GCOL GET GET$ GOSUB GOTO HIMEM IF INKEY INKEY$ INPUT INSTR INT LEFT$ LEN LET LINE LIST LN LOAD ' +
      'LOCAL LOG LOMEM MID$ MOD MODE MOVE NEW NEXT NOT OFF OLD ON OPENIN OPENOUT OPENUP OR OSCLI PAGE PI ' +
      'PLOT POINT POS PRINT PROC PTR RAD READ REM RENUMBER REPEAT REPORT RESTORE RETURN RIGHT$ RND RUN SAVE ' +
      'SGN SIN SOUND SPC SQR STEP STOP STR$ STRING$ TAB TAN THEN TIME TO TOP TRACE TRUE UNTIL USR VAL VDU ' +
      'VPOS WIDTH',
  },
  'msx-basic': {
    name: 'MSX-BASIC',
    crunched: true, apostrophe: true, question: true,
    words: `${MS_CORE} AUTO BASE BEEP BIN$ BLOAD BSAVE CALL CDBL CINT CIRCLE CLOAD CLOSE CLS COLOR COPY ` +
      'CSAVE CSNG CSRLIN DEFDBL DEFINT DEFSNG DEFSTR DELETE DRAW ELSE EOF EQV ERASE ERL ERR ERROR FIX FILES ' +
      'HEX$ IMP INKEY$ INP INSTR INTERVAL KEY KILL LINE LOCATE LPRINT MAX MERGE MOD MOTOR NAME OCT$ OFF OPEN ' +
      'OUT PAD PAINT PDL PLAY POINT PRESET PSET PUT RENUM RESUME SCREEN SET SOUND SPACE$ SPRITE STICK STRIG ' +
      'STRING$ SWAP TIME TROFF TRON USING VARPTR VDP VPEEK VPOKE WIDTH XOR',
  },
  'locomotive-basic': {
    name: 'Locomotive BASIC',
    crunched: false, apostrophe: true,
    words: 'ABS AFTER AND ASC ATN AUTO BIN$ BORDER CALL CAT CHAIN CHR$ CINT CLEAR CLG CLOSEIN CLOSEOUT CLS ' +
      'CONT COS CREAL DATA DEF DEFINT DEFREAL DEFSTR DEG DELETE DI DIM DRAW DRAWR EDIT EI ELSE END ENT ENV ' +
      'EOF ERASE ERL ERR ERROR EVERY EXP FILL FIX FN FOR FRAME FRE GOSUB GOTO GRAPHICS HEX$ IF INK INKEY ' +
      'INKEY$ INP INPUT INSTR INT JOY KEY LEFT$ LEN LET LINE LIST LOAD LOCATE LOG LOG10 LOWER$ MASK MAX ' +
      'MEMORY MERGE MID$ MIN MOD MODE MOVE MOVER NEW NEXT NOT ON OPENIN OPENOUT OR ORIGIN OUT PAPER PEEK PEN ' +
      'PI PLOT PLOTR POKE POS PRINT RAD RANDOMIZE READ RELEASE REM REMAIN RENUM RESTORE RESUME RETURN ' +
      'RIGHT$ RND ROUND RUN SAVE SGN SIN SOUND SPACE$ SPC SPEED SQ SQR STEP STOP STR$ STRING$ SYMBOL TAB ' +
      'TAG TAGOFF TAN TEST TESTR THEN TIME TO TROFF TRON UNT UPPER$ USING VAL VPOS WAIT WEND WHILE WIDTH ' +
      'WINDOW WRITE XOR XPOS YPOS ZONE',
  },
  superbasic: {
    name: 'SuperBASIC',
    crunched: false,
    words: 'ABS ACOS ACOT ADATE AND ASIN AT ATAN AUTO BAUD BEEP BLOCK BORDER CALL CHR$ CIRCLE CLEAR CLOSE CLS ' +
      'CODE CONTINUE COPY COS COT CSIZE CURSOR DATA DATE DATE$ DAY$ DEFINE DEG DELETE DIM DIMN DIR DIV DLINE ' +
      'EDIT ELLIPSE ELSE END EOF EXEC EXIT EXP FILL FILL$ FLASH FOR FORMAT FUNCTION GO GOSUB GOTO IF INK ' +
      'INKEY$ INPUT INSTR INT KEYROW LBYTES LEN LET LINE LIST LN LOAD LOCAL LOG10 LRUN MERGE MOD MODE MOVE ' +
      'MRUN NEW NEXT NOT ON OPEN OR OVER PAN PAPER PAUSE PEEK PENDOWN PENUP PI POINT POKE PRINT PROCEDURE ' +
      'RAD RANDOMISE READ RECOL REMAINDER REM RENUM REPEAT RESPR RESTORE RETRY RETURN RND RUN SAVE SCALE ' +
      'SCROLL SDATE SELECT SEXEC SIN SQRT STEP STOP STRIP TAN THEN TO TURN TURNTO UNDER WIDTH WINDOW XOR',
  },
  'sam-basic': {
    name: 'SAM BASIC',
    crunched: false,
    words: 'ABS AND AT BEEP BLITZ BOOT BORDER BRIGHT CALL CHR$ CIRCLE CLEAR CLS CODE COPY COS CSIZE DATA DEF ' +
      'DEFAULT DELETE DIM DIR DIV DO DPEEK DPOKE DRAW ELSE END ERASE EXIT FILL FLASH FN FOR FORMAT GET GO ' +
      'GOSUB GOTO GRAB IF INK INKEY$ INPUT INT INVERSE KEY LEN LET LIST LOAD LOCAL LOOP MERGE MOD MODE NEW ' +
      'NEXT NOT ON OR OVER PALETTE PAPER PAUSE PEEK PEN PLOT POKE PRINT PROC PUT READ RECORD REM RENUM ' +
      'RESTORE RETURN RND ROLL RUN SAVE SCREEN SCROLL SIN SOUND SQR STEP STOP STR$ TAB THEN TIME TO UNTIL ' +
      'VAL VERIFY WHILE WINDOW ZAP',
  },
  'oric-basic': {
    name: 'Oric BASIC',
    crunched: true, question: true,
    words: `${MS_CORE} CALL CHAR CIRCLE CLOAD CLS CSAVE CURMOV CURSET DEEK DOKE DRAW ELSE EXPLODE FILL ` +
      'GRAB HIMEM HIRES INK INVERSE KEY$ LORES MUSIC NORMAL PAPER PATTERN PING PLAY PLOT POINT PULL ' +
      'RELEASE REPEAT SCRN SHOOT SOUND TEXT TROFF TRON UNTIL ZAP',
  },
  'color-basic': {
    name: 'Dragon BASIC',
    crunched: true, question: true,
    words: `${MS_CORE} AUDIO CIRCLE CLOAD CLOSE CLS COLOR CSAVE DEL DLOAD DRAW EDIT ELSE EXEC FIX HEX$ ` +
      'INKEY$ INSTR JOYSTK LINE MEM MOTOR OPEN PAINT PCLEAR PCLS PCOPY PLAY PMODE POINT PPOINT PRESET PSET ' +
      'PUT RENUM RESET SCREEN SET SKIPF SOUND STRING$ TIMER TROFF TRON USING VARPTR',
  },
  applesoft: {
    name: 'Applesoft BASIC',
    crunched: true,
    words: `${MS_CORE} CALL COLOR DEL DRAW FLASH GR HCOLOR HGR HGR2 HIMEM HLIN HOME HPLOT HTAB INVERSE LOMEM ` +
      'NORMAL NOTRACE ONERR PDL PLOT POP RECALL RESUME ROT SCALE SCRN SHLOAD SPEED STORE TEXT TRACE VLIN ' +
      'VTAB XDRAW',
  },
  'kc-basic': {
    name: 'HC-BASIC',
    crunched: true,
    // The KC 85/4's 8 KB BASIC ROM plus the graphics, sound and window words CAOS 4.2
    // adds (both token tables read from the shipping ROMs). The machine
    // accepts keywords in either case (measured on a rig, 2026-10-04).
    words: 'END FOR NEXT DATA INPUT DIM READ LET GOTO RUN IF RESTORE GOSUB RETURN REM STOP OUT ON NULL WAIT DEF ' +
      'POKE DOKE AUTO LINES CLS WIDTH BYE CALL PRINT CONT LIST CLEAR CLOAD CSAVE NEW TAB TO FN SPC THEN NOT ' +
      'STEP AND OR SGN INT ABS USR FRE INP POS SQR RND LN EXP COS SIN TAN ATN PEEK DEEK PI LEN STR$ VAL ASC ' +
      'CHR$ LEFT$ RIGHT$ MID$ LOAD TRON TROFF EDIT ELSE INKEY$ JOYST STRING$ INSTR RENUMBER DELETE PAUSE BEEP ' +
      'WINDOW BORDER INK PAPER AT COLOR SOUND PSET PRESET BLOAD VPEEK VPOKE LOCATE KEYLIST KEY SWITCH PTEST ' +
      'CLOSE OPEN RANDOMIZE VGET$ LINE CIRCLE CSRLIN',
  },
};

const SPECS = new Map<BasicDialect, DialectSpec>();

/** The highlighter's view of one dialect (built once, then shared). */
export function dialectSpec(dialect: BasicDialect): DialectSpec {
  let spec = SPECS.get(dialect);
  if (!spec) {
    const w = WORDS[dialect];
    const keywords = new Set(w.words.split(/\s+/).filter(Boolean));
    spec = {
      name: w.name,
      keywords,
      byLength: [...keywords].sort((a, b) => b.length - a.length),
      crunched: w.crunched,
      apostropheComment: !!w.apostrophe,
      questionPrint: !!w.question,
      braceTokens: !!w.braces,
    };
    SPECS.set(dialect, spec);
  }
  return spec;
}

/** Every dialect the editor knows — the registry's enum must stay a subset. */
export const DIALECTS = Object.keys(WORDS) as BasicDialect[];
