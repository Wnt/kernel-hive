p = "src/CMakeLists.txt"
s = open(p).read()
if "abspointer.c" not in s:
    s = s.replace("set(SOURCES\n\tadb.c", "set(SOURCES\n\tabspointer.c adb.c", 1)
    open(p, "w").write(s)
p = "src/main.c"
s = open(p).read()
if "abspointer.h" not in s:
    s = s.replace('#include "main.h"', '#include "main.h"\n#include "abspointer.h"', 1)
if "AbsPointer_Poll();" not in s:
    s = s.replace("\tTiming_Sync();", "\tAbsPointer_Poll();\n\n\tTiming_Sync();", 1)
if "AbsPointer_Init();" not in s:
    s = s.replace(
        "\t/* Get an event ID for our special event */",
        "\tAbsPointer_Init();\n\n\t/* Get an event ID for our special event */",
        1,
    )
open(p, "w").write(s)
print("patched")
