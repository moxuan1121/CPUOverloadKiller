// Host regression tests for VDTProcessIdentity.
//
// These cover the two failure modes that reached production:
//   1. proc_pidpath/proc_name returning failure while the caller used the buffer
//      anyway (the runningboardd SIGABRT in 1.1.5).
//   2. Daemon-name matching against the kernel's fixed-size p_comm, while the
//      preference bundle stores the full executable name. Any daemon beyond that
//      cap could never match its own config.

#include "../VDTProcessIdentity.h"

#include <assert.h>
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

static int emptyStringReader(int pid, void *buffer, uint32_t bufferSize) {
    (void)pid;
    readerCalls++;
    if (bufferSize > 0) {
        ((char *)buffer)[0] = '\0';
    }
    return 1;
}

static int unterminatedReader(int pid, void *buffer, uint32_t bufferSize) {
    (void)pid;
    readerCalls++;
    memset(buffer, 'A', bufferSize);
    return (int)bufferSize;
}

static int goodReader(int pid, void *buffer, uint32_t bufferSize) {
    (void)pid;
    readerCalls++;
    const char *value = "/usr/libexec/trustd";
    size_t len = strlen(value);
    if (len + 1 > bufferSize) return 0;
    memcpy(buffer, value, len + 1);
    return (int)len;
}

static void test_copy_process_info_string(void) {
    char buffer[128];

    // Reader reports failure: caller must not observe stale or partial data.
    readerCalls = 0;
    memset(buffer, 'Z', sizeof(buffer));
    assert(!VDTCopyProcessInfoString(42, buffer, sizeof(buffer), failingReader));
    assert(readerCalls == 1);
    assert(buffer[0] == '\0');

    readerCalls = 0;
    memset(buffer, 'Z', sizeof(buffer));
    assert(!VDTCopyProcessInfoString(42, buffer, sizeof(buffer), negativeReader));
    assert(readerCalls == 1);
    assert(buffer[0] == '\0');

    // Reader claims success but wrote an empty string.
    readerCalls = 0;
    assert(!VDTCopyProcessInfoString(42, buffer, sizeof(buffer), emptyStringReader));
    assert(readerCalls == 1);
    assert(buffer[0] == '\0');

    // Reader filled the buffer without a NUL terminator.
    readerCalls = 0;
    assert(!VDTCopyProcessInfoString(42, buffer, sizeof(buffer), unterminatedReader));
    assert(readerCalls == 1);
    assert(buffer[0] == '\0');

    // Dead or invalid PIDs must never reach the syscall.
    readerCalls = 0;
    assert(!VDTCopyProcessInfoString(0, buffer, sizeof(buffer), goodReader));
    assert(!VDTCopyProcessInfoString(-1, buffer, sizeof(buffer), goodReader));
    assert(readerCalls == 0);

    // Degenerate buffers must be rejected before the reader runs.
    readerCalls = 0;
    assert(!VDTCopyProcessInfoString(42, buffer, 0, goodReader));
    assert(!VDTCopyProcessInfoString(42, buffer, 1, goodReader));
    assert(!VDTCopyProcessInfoString(42, NULL, sizeof(buffer), goodReader));
    assert(!VDTCopyProcessInfoString(42, buffer, sizeof(buffer), NULL));
    assert(readerCalls == 0);

    // Happy path.
    readerCalls = 0;
    assert(VDTCopyProcessInfoString(42, buffer, sizeof(buffer), goodReader));
    assert(readerCalls == 1);
    assert(strcmp(buffer, "/usr/libexec/trustd") == 0);
}

static void test_last_path_component(void) {
    char out[64];

    assert(VDTCopyLastPathComponent("/usr/libexec/trustd", out, sizeof(out)));
    assert(strcmp(out, "trustd") == 0);

    assert(VDTCopyLastPathComponent("trustd", out, sizeof(out)));
    assert(strcmp(out, "trustd") == 0);

    // Trailing slashes must not yield an empty name.
    assert(VDTCopyLastPathComponent("/usr/libexec/trustd/", out, sizeof(out)));
    assert(strcmp(out, "trustd") == 0);

    // Degenerate inputs.
    assert(!VDTCopyLastPathComponent("/", out, sizeof(out)));
    assert(!VDTCopyLastPathComponent("", out, sizeof(out)));
    assert(!VDTCopyLastPathComponent(NULL, out, sizeof(out)));
    assert(!VDTCopyLastPathComponent("/usr/libexec/trustd", out, 3));

    // Exact-fit boundary: buffer holds name + NUL exactly.
    char exact[7]; // "trustd" + NUL = 7 bytes
    assert(VDTCopyLastPathComponent("/usr/libexec/trustd", exact, sizeof(exact)));
    assert(strcmp(exact, "trustd") == 0);

    // One byte short must fail.
    char tight[6];
    assert(!VDTCopyLastPathComponent("/usr/libexec/trustd", tight, sizeof(tight)));
}

static void test_daemon_name_matching(void) {
    // Matching rule under test:
    //   * If the full executable name is available, it is authoritative and must
    //     equal the configured name.
    //   * Otherwise p_comm is an exact-match fallback only. It may be truncated,
    //     so guessing from a prefix is not safe enough for a fatal CPU limit.

    // Executable name available and authoritative.
    assert(VDTProcessNameMatches("trustd", "trustd", "trustd"));
    assert(!VDTProcessNameMatches("trustd", "installd", "installd"));

    // The defect this function exists for: the preference bundle stores the full
    // executable name, so a long daemon can only match via the executable name.
    assert(VDTProcessNameMatches("PerfPowerServicesExtended",
                                 "PerfPowerServicesExtended",
                                 "PerfPowerService"));

    // Executable name unavailable (NULL or empty are both "unavailable"). A
    // truncated p_comm must not be treated as proof of a match.
    assert(!VDTProcessNameMatches("PerfPowerServicesExtended", NULL, "PerfPowerService"));
    assert(!VDTProcessNameMatches("PerfPowerServicesExtended", "", "PerfPowerService"));
    assert(!VDTProcessNameMatches("ScreenTimeAgentExtra", "", "ScreenTimeAgentE"));

    // Exact short-name fallback remains valid.
    assert(!VDTProcessNameMatches("navdaemon", "", "navd"));
    assert(VDTProcessNameMatches("navd", "", "navd"));
    assert(VDTProcessNameMatches("ScreenTimeAgent", "", "ScreenTimeAgent"));

    // A mismatching executable name must not fall through to p_comm.
    assert(!VDTProcessNameMatches("trustd", "installd", "trustd"));

    // Empty and NULL inputs must never match.
    assert(!VDTProcessNameMatches("", "", ""));
    assert(!VDTProcessNameMatches(NULL, "trustd", "trustd"));
    assert(!VDTProcessNameMatches("trustd", NULL, NULL));
    assert(!VDTProcessNameMatches("trustd", "", ""));
}

int main(void) {
    test_copy_process_info_string();
    test_last_path_component();
    test_daemon_name_matching();
    printf("process identity guard tests passed\n");
    return 0;
}
