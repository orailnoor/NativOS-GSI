# NativOS package-installed CLI fallback; no host privilege elevation.
command_not_found_handle() {
    /usr/local/bin/nativos-packages run "/usr/bin/$1" "${@:2}"
}
