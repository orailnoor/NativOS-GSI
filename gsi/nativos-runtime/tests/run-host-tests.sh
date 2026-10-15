#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /tmp/nativos-runtime-tests.XXXXXX)"
trap 'rm -rf -- "$build_dir"' EXIT
c++ -std=c++17 -Wall -Wextra -Werror "$source_dir/tests/protocol_test.cpp" -o "$build_dir/protocol_test"
"$build_dir/protocol_test"
bash "$source_dir/tests/public-config-test.sh"
python3 "$source_dir/tests/client_policy_test.py"
python3 "$source_dir/../packages/tests.py"
python3 "$source_dir/../packages/test-transaction-locks.py"
python3 "$source_dir/../packages/test-guest-compat.py"
python3 "$source_dir/tests/flatpak_preflight_test.py"
c++ -std=c++17 -Wall -Wextra -Werror "$source_dir/src/nativosd.cpp" -o "$build_dir/nativosd"
set +e
env -u ANDROID_SOCKET_nativos_runtime "$build_dir/nativosd"
result=$?
set -e
test "$result" -eq 1
printf '%s\n' 'Daemon compiled; missing init socket correctly rejected'
python3 "$source_dir/tests/socket_test.py" "$build_dir/nativosd"
c++ -std=c++17 -Wall -Wextra -Werror "$source_dir/tests/privilege_test.cpp" -o "$build_dir/privilege_test"
if [ "$(id -u)" -eq 0 ]; then
    "$build_dir/privilege_test"
    c++ -std=c++17 -Wall -Wextra -Werror "$source_dir/tests/storage_test.cpp" -o "$build_dir/storage_test"
    mkdir "$build_dir/storage"
    "$build_dir/storage_test" "$build_dir/storage"
    c++ -std=c++17 -Wall -Wextra -Werror "$source_dir/tests/supervisor_test.cpp" "$source_dir/src/session_supervisor.cpp" -o "$build_dir/supervisor_test"
    timeout 15 "$build_dir/supervisor_test"
    c++ -std=c++17 -Wall -Wextra -Werror -DNATIVOS_TEST_NO_PID_NAMESPACE "$source_dir/tests/supervisor_test.cpp" "$source_dir/src/session_supervisor.cpp" -o "$build_dir/supervisor_fallback_test"
    timeout 15 "$build_dir/supervisor_fallback_test"
else
    printf '%s\n' 'SKIP: run this script as WSL root to exercise privilege dropping'
fi
