#include "VDTProcessIdentity.h"

#include <string.h>

bool VDTProcessInstanceTokenIsValid(VDTProcessInstanceToken token) {
    return (token.seconds != 0 || token.microseconds != 0) &&
        token.microseconds < 1000000;
}

bool VDTProcessInstanceMatches(VDTProcessInstanceToken expected,
                               VDTProcessInstanceToken current) {
    return VDTProcessInstanceTokenIsValid(expected) &&
        VDTProcessInstanceTokenIsValid(current) &&
        expected.seconds == current.seconds &&
        expected.microseconds == current.microseconds;
}

bool VDTCopyProcessInfoString(pid_t pid,
                              char *buffer,
                              uint32_t bufferSize,
                              VDTProcessInfoReader reader) {
    if (!buffer || bufferSize == 0) {
        return false;
    }

    // Leave a usable empty string behind for every rejection path below.
    buffer[0] = '\0';

    if (pid <= 0 || bufferSize < 2 || !reader) {
        return false;
    }

    memset(buffer, 0, bufferSize);
    int result = reader(pid, buffer, bufferSize);
    if (result <= 0 || buffer[0] == '\0' || !memchr(buffer, '\0', bufferSize)) {
        buffer[0] = '\0';
        return false;
    }

    return true;
}

bool VDTCopyLastPathComponent(const char *path, char *out, uint32_t outSize) {
    if (!out || outSize == 0) {
        return false;
    }

    out[0] = '\0';

    if (!path) {
        return false;
    }

    size_t end = strlen(path);
    if (end == 0) {
        return false;
    }

    // Ignore trailing slashes so "/usr/libexec/trustd/" still yields "trustd".
    while (end > 0 && path[end - 1] == '/') {
        end--;
    }
    if (end == 0) {
        return false;
    }

    size_t start = end;
    while (start > 0 && path[start - 1] != '/') {
        start--;
    }

    size_t length = end - start;
    if (length == 0 || length + 1 > outSize) {
        return false;
    }

    memcpy(out, path + start, length);
    out[length] = '\0';
    return true;
}

bool VDTProcessNameMatches(const char *configuredName,
                           const char *executableName,
                           const char *procComm) {
    if (!configuredName || configuredName[0] == '\0') {
        return false;
    }

    // The executable name comes from the same source the preference bundle used
    // (the last path component of the executable), so it is authoritative and is
    // never allowed to fall through to the truncated p_comm.
    if (executableName && executableName[0] != '\0') {
        return strcmp(configuredName, executableName) == 0;
    }

    if (!procComm || procComm[0] == '\0') {
        return false;
    }

    // Fail closed when only p_comm is available. The kernel may truncate it, so
    // prefix matching could apply a configured process's fatal limit to a
    // different process with the same prefix.
    return strcmp(configuredName, procComm) == 0;
}
