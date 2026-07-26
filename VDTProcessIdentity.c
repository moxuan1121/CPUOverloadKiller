#include "VDTProcessIdentity.h"

#include <string.h>

bool VDTCopyProcessInfoString(pid_t pid,
                              char *buffer,
                              uint32_t bufferSize,
                              VDTProcessInfoReader reader) {
    if (buffer && bufferSize > 0) {
        buffer[0] = '\0';
    }
    if (pid <= 0 || !buffer || bufferSize < 2 || !reader) {
        return false;
    }

    memset(buffer, 0, bufferSize);
    int result = reader(pid, buffer, bufferSize);
    if (result <= 0 || buffer[0] == '\0') {
        buffer[0] = '\0';
        return false;
    }
    if (!memchr(buffer, '\0', bufferSize)) {
        buffer[0] = '\0';
        return false;
    }

    return true;
}
