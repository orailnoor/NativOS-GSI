#!/usr/bin/env bash
set -euo pipefail
global_value=0
user_value=0
settings() {
    case "$*" in
      'put global device_provisioned 1') global_value=1 ;;
      '--user 0 put secure user_setup_complete 1') user_value=1 ;;
      'get global device_provisioned') printf '%s\n' "$global_value" ;;
      '--user 0 get secure user_setup_complete') printf '%s\n' "$user_value" ;;
      *) printf 'Unexpected settings request: %s\n' "$*" >&2; return 1 ;;
    esac
}
firstboot="$(dirname -- "${BASH_SOURCE[0]}")/../../nativos-firstboot.sh"
source "$firstboot"
[[ "$global_value" == 1 && "$user_value" == 1 ]]
source "$firstboot"
[[ "$global_value" == 1 && "$user_value" == 1 ]]
printf '%s\n' 'Firstboot mock tests passed: primary user only, repeatable setup flags'
