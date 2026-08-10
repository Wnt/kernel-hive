#
# solaris GOLDEN TEST FIXTURE front-panel override.
# Removes the built-in analog Clock control (CONTROL Clock, TYPE clock -- the
# leftmost globe-with-hands) so the front panel has NO per-minute minute-hand
# repaint. This makes the idle framebuffer byte-stable for before/after test
# screenshots. dtwm reads this via dtSearchPath (/etc/dt precedes /usr/dt).
#
CONTROL Clock
{
  CONTAINER_NAME  Top
  CONTAINER_TYPE  BOX
  DELETE          True
}
