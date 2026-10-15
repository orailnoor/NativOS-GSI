#!/system/bin/sh
# Called by init as shell after Android services are available. Primary user
# only; never touches account protection, bootloader state or device management.
set -eu
settings put global device_provisioned 1
settings --user 0 put secure user_setup_complete 1
test "$(settings get global device_provisioned)" = 1
test "$(settings --user 0 get secure user_setup_complete)" = 1
