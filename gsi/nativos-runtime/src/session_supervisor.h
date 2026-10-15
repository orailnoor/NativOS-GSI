#pragma once
namespace nativos {
// Call only in a disposable, single-threaded runner process. Entry executes in
// a child of namespace PID 1. It MUST prepare the rootfs and drop privileges
// before executing any Linux payload. This helper alone is not a sandbox.
int superviseSession(int (*entry)());
}
