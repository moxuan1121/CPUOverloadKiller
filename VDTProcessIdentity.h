#ifndef VDT_PROCESS_IDENTITY_H
#define VDT_PROCESS_IDENTITY_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*VDTProcessInfoReader)(int pid, void *buffer, uint32_t bufferSize);

bool VDTCopyProcessInfoString(pid_t pid,
                              char *buffer,
                              uint32_t bufferSize,
                              VDTProcessInfoReader reader);

#ifdef __cplusplus
}
#endif

#endif
