#ifndef VDT_PROCESS_IDENTITY_H
#define VDT_PROCESS_IDENTITY_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*VDTProcessInfoReader)(int pid, void *buffer, uint32_t bufferSize);

// Runs `reader` and only reports success when the buffer holds a non-empty,
// NUL-terminated string. On failure the buffer is left as an empty string so
// callers can never consume stale or partial data.
bool VDTCopyProcessInfoString(pid_t pid,
                              char *buffer,
                              uint32_t bufferSize,
                              VDTProcessInfoReader reader);

// Copies the last path component of `path` into `out`. Trailing slashes are
// ignored. Returns false for NULL/empty input, root-only paths, and when `out`
// is too small.
bool VDTCopyLastPathComponent(const char *path, char *out, uint32_t outSize);

// Decides whether a running process matches a configured daemon name.
//
// `executableName` (the last path component of proc_pidpath) is authoritative
// when available. `procComm` (proc_name) is only an exact-match fallback. It may
// be truncated by the kernel, so prefix matching would risk controlling a
// different process that happens to share the same prefix.
bool VDTProcessNameMatches(const char *configuredName,
                           const char *executableName,
                           const char *procComm);

#ifdef __cplusplus
}
#endif

#endif
