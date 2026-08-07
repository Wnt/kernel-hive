/* REXX - restore the OS/2 Warp gallery desktop program objects.
 *
 * MCP2/GENGRADD upgrades can preserve an OBJECTID while moving its object out
 * of <WP_DESKTOP>.  SysCreateObject(..., 'U') then reports success but only
 * updates that hidden object.  Destroy and recreate the gallery-owned objects
 * after WPS has settled so their container and positions are deterministic.
 *
 * Deploy this file as C:\STARTUP.CMD.  It starts the serial pointer agent,
 * waits 60 seconds for WPS to settle, and then restores the inventory.  The
 * object creation cannot be chained to a second .CMD file: OS/2 reports SYS1803
 * when one REXX batch file launches another as a command.
 */
call RxFuncAdd 'SysLoadFuncs', 'REXXUTIL', 'SysLoadFuncs'
call SysLoadFuncs

'start C:\WARPD.EXE'
say 'Setting up the gallery desktop, please wait...'
call SysSleep 60

desktop = '<WP_DESKTOP>'

setup = 'EXENAME=C:\OS2\APPS\KLONDIKE.EXE;ICONPOS=23,90'
call Recreate 'WPProgram', 'Klondike Solitaire', setup, '<GAL_KLONDIKE>'
setup = 'EXENAME=C:\OS2\APPS\OS2CHESS.EXE;ICONPOS=35,90'
call Recreate 'WPProgram', 'OS/2 Chess', setup, '<GAL_CHESS>'
setup = 'EXENAME=C:\OS2\APPS\MAHJONGG.EXE;ICONPOS=46,90'
call Recreate 'WPProgram', 'Mahjongg', setup, '<GAL_MAHJONGG>'
setup = 'EXENAME=C:\OS2\CMD.EXE;PARAMETERS=/C C:\GAMES\DOOM\DOOMFS.CMD;'
setup = setup || 'STARTUPDIR=C:\GAMES\DOOM;ICONPOS=59,90'
call Recreate 'WPProgram', 'DOOM (shareware)', setup, '<GAL_DOOM>'
setup = 'EXENAME=C:\OS2\APPS\EPM.EXE;ICONPOS=70,90'
call Recreate 'WPProgram', 'System Editor (EPM)', setup, '<GAL_EPM>'
setup = 'PROGTYPE=PROG_WINDOWABLEVIO;EXENAME=C:\OS2\CMD.EXE;ICONPOS=84,90'
call Recreate 'WPProgram', 'OS/2 Window', setup, '<GAL_CMDLINE>'

/* These system-owned targets survive MCP2.  Gallery-owned shadows keep the
 * original WebExplorer and Get Netscape Navigator icons and launch settings. */
setup = 'SHADOWID=<TCPIP_WEB>;ICONPOS=8,22'
call Recreate 'WPShadow', 'WebExplorer', setup, '<GAL_WEBEXPLORER>'
setup = 'SHADOWID=<URL_GETNETSCAPE>;ICONPOS=20,22'
call Recreate 'WPShadow', 'Get Netscape Navigator', setup, '<GAL_GETNETSCAPE>'

'exit'
exit 0

Recreate: procedure expose desktop
  parse arg class, title, setup, object_id
  call SysDestroyObject object_id
  setup = setup || ';OBJECTID=' || object_id
  created = SysCreateObject(class, title, desktop, setup, 'U')
  say title || ': ' || created
  return
