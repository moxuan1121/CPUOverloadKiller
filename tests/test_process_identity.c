#include "VDTProcessIdentity.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int readerCalls;

static int failingReader(int pid, void *buffer, uint32_t bufferSize) {
    (void)pid;
    (void)buffer;
    (void)bufferSize;
    readerCalls++;
    return 0;
}

static int negativeReader(int pid, void *buffer, uint32_t bufferSize) {
    (void)pid;
    (void)buffer;
    (void)bufferSize;
    readerCalls++;
    return -1;
}

static int emptyReader(int pid, void *buffer, uint32_t bufferSize) {
    (void)pid;
    readerCalls++;
    memset(buffer, 0, bufferSize);
    return 1;
}

static int unterminatedReader(int pid, void *buffer, uint32_t bufferSize) {
    (void)pid;
    readerCalls++;
    memset(buffer, 'x', bufferSize);
    return (int)bufferSize;
}

static int validReader(int pid, void *buffer, uint32_t bufferSize) {
    (void)pid;
    readerCalls++;
    const char value[] = "/Applications/Test.app/Test";
    assert(sizeof(value) <= bufferSize);
    memcpy(buffer, value, sizeof(value));
    return (int)(sizeof(value) - 1);
}

int main(void) {
    char buffer[64];

    readerCalls = 0;
    assert(!VDTCopyProcessInfoString(0, buffer, sizeof(buffer), failingReader));
    assert(readerCalls == 0);

    readerCalls = 0;
    assert(!VDTCopyProcessInfoString(123, buffer, sizeof(buffer), NULL));
    assert(readerCalls == 0);

    assert(!VDTCopyProcessInfoString(123, NULL, sizeof(buffer), failingReader));
    assert(!VDTCopyProcessInfoString(123, buffer, 1, failingReader));

    assert(!VDTCopyProcessInfoString(123, buffer, sizeof(buffer), failingReader));
    assert(buffer[0] == '\0');

    assert(!VDTCopyProcessInfoString(123, buffer, sizeof(buffer), negativeReader));
    assert(buffer[0] == '\0');

    assert(!VDTCopyProcessInfoString(123, buffer, sizeof(buffer), emptyReader));
    assert(!VDTCopyProcessInfoString(123, buffer, sizeof(buffer), unterminatedReader));

    assert(VDTCopyProcessInfoString(123, buffer, sizeof(buffer), validReader));
    assert(strcmp(buffer, "/Applications/Test.app/Test") == 0);

    puts("process identity guard tests passed");
    return 0;
}
