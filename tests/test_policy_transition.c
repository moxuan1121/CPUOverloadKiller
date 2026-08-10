#include "../VDTPolicyTransition.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

enum {
    CallClear = 1,
    CallDisable,
    CallDefaults,
    CallResume,
    CallThrottle,
    CallFatal,
};

typedef struct {
    int calls[16];
    size_t callCount;
    int identityChecks;
    int rejectIdentityAtCheck;
    int clearResult;
    int disableResult;
    int defaultsResult;
    int resumeResult;
    int throttleResult;
    int fatalResult;
} FakeState;

static void record(FakeState *state, int call) {
    assert(state->callCount < sizeof(state->calls) / sizeof(state->calls[0]));
    state->calls[state->callCount++] = call;
}

static bool identityCurrent(pid_t pid, void *context) {
    FakeState *state = context;
    assert(pid == 42);
    state->identityChecks++;
    return state->rejectIdentityAtCheck == 0 ||
        state->identityChecks != state->rejectIdentityAtCheck;
}

static int clearCpuLimits(pid_t pid, void *context) {
    FakeState *state = context;
    assert(pid == 42);
    record(state, CallClear);
    return state->clearResult;
}

static int disableCpuMonitor(pid_t pid, void *context) {
    FakeState *state = context;
    assert(pid == 42);
    record(state, CallDisable);
    return state->disableResult;
}

static int setCpuMonitorDefaults(pid_t pid, void *context) {
    FakeState *state = context;
    assert(pid == 42);
    record(state, CallDefaults);
    return state->defaultsResult;
}

static int resumeCpuMonitor(pid_t pid, void *context) {
    FakeState *state = context;
    assert(pid == 42);
    record(state, CallResume);
    return state->resumeResult;
}

static int setThrottle(pid_t pid, int percentage, void *context) {
    FakeState *state = context;
    assert(pid == 42);
    assert(percentage == 80);
    record(state, CallThrottle);
    return state->throttleResult;
}

static int setFatal(pid_t pid, int percentage, int interval, void *context) {
    FakeState *state = context;
    assert(pid == 42);
    assert(percentage == 80);
    assert(interval == 120);
    record(state, CallFatal);
    return state->fatalResult;
}

static VDTPolicyOperations operations(FakeState *state) {
    VDTPolicyOperations ops = {
        .identityCurrent = identityCurrent,
        .clearCpuLimits = clearCpuLimits,
        .disableCpuMonitor = disableCpuMonitor,
        .setCpuMonitorDefaults = setCpuMonitorDefaults,
        .resumeCpuMonitor = resumeCpuMonitor,
        .setThrottle = setThrottle,
        .setFatal = setFatal,
        .context = state,
    };
    return ops;
}

static void assertCalls(const FakeState *state, const int *expected, size_t count) {
    assert(state->callCount == count);
    assert(memcmp(state->calls, expected, count * sizeof(expected[0])) == 0);
}

static void test_throttle_success(void) {
    FakeState state = {0};
    VDTPolicyOperations ops = operations(&state);
    VDTPolicyTransitionResult result = VDTApplyPolicyTransition(
        42, VDTPolicyModeThrottle, 80, 120, &ops);
    const int expected[] = {CallDisable, CallThrottle};

    assert(result.success);
    assert(!result.identityRejected);
    assertCalls(&state, expected, sizeof(expected) / sizeof(expected[0]));
    assert(state.identityChecks == 2);
}

static void test_fatal_success(void) {
    FakeState state = {0};
    VDTPolicyOperations ops = operations(&state);
    VDTPolicyTransitionResult result = VDTApplyPolicyTransition(
        42, VDTPolicyModeFatal, 80, 120, &ops);
    const int expected[] = {CallClear, CallDisable, CallFatal, CallResume};

    assert(result.success);
    assert(!result.identityRejected);
    assertCalls(&state, expected, sizeof(expected) / sizeof(expected[0]));
    assert(state.identityChecks == 4);
}

static void test_retirement_failure_blocks_new_policy(void) {
    FakeState throttleState = {.disableResult = -1};
    VDTPolicyOperations throttleOps = operations(&throttleState);
    VDTPolicyTransitionResult throttleResult = VDTApplyPolicyTransition(
        42, VDTPolicyModeThrottle, 80, 120, &throttleOps);
    const int throttleExpected[] = {CallDisable};

    assert(!throttleResult.success);
    assert(throttleResult.retirementFailed);
    assertCalls(&throttleState, throttleExpected,
        sizeof(throttleExpected) / sizeof(throttleExpected[0]));

    FakeState fatalState = {.clearResult = -1};
    VDTPolicyOperations fatalOps = operations(&fatalState);
    VDTPolicyTransitionResult fatalResult = VDTApplyPolicyTransition(
        42, VDTPolicyModeFatal, 80, 120, &fatalOps);
    const int fatalExpected[] = {CallClear};

    assert(!fatalResult.success);
    assert(fatalResult.retirementFailed);
    assertCalls(&fatalState, fatalExpected,
        sizeof(fatalExpected) / sizeof(fatalExpected[0]));
}

static void test_identity_is_checked_before_each_syscall(void) {
    FakeState state = {.rejectIdentityAtCheck = 2};
    VDTPolicyOperations ops = operations(&state);
    VDTPolicyTransitionResult result = VDTApplyPolicyTransition(
        42, VDTPolicyModeThrottle, 80, 120, &ops);
    const int expected[] = {CallDisable};

    assert(!result.success);
    assert(result.identityRejected);
    assertCalls(&state, expected, sizeof(expected) / sizeof(expected[0]));
}

static void test_fatal_set_failure_is_not_resumed(void) {
    FakeState state = {.fatalResult = -1};
    VDTPolicyOperations ops = operations(&state);
    VDTPolicyTransitionResult result = VDTApplyPolicyTransition(
        42, VDTPolicyModeFatal, 80, 120, &ops);
    const int expected[] = {CallClear, CallDisable, CallFatal};

    assert(!result.success);
    assert(!result.retirementFailed);
    assertCalls(&state, expected, sizeof(expected) / sizeof(expected[0]));
}

static void test_restore_stops_if_identity_changes(void) {
    FakeState state = {.rejectIdentityAtCheck = 3};
    VDTPolicyOperations ops = operations(&state);
    VDTPolicyTransitionResult result = VDTApplyPolicyTransition(
        42, VDTPolicyModeRestore, 0, 0, &ops);
    const int expected[] = {CallClear, CallDisable};

    assert(!result.success);
    assert(result.identityRejected);
    assertCalls(&state, expected, sizeof(expected) / sizeof(expected[0]));
}

static void test_restore_is_best_effort(void) {
    FakeState state = {
        .clearResult = -1,
        .disableResult = -1,
        .defaultsResult = -1,
        .resumeResult = -1,
    };
    VDTPolicyOperations ops = operations(&state);
    VDTPolicyTransitionResult result = VDTApplyPolicyTransition(
        42, VDTPolicyModeRestore, 0, 0, &ops);
    const int expected[] = {CallClear, CallDisable, CallDefaults, CallResume};

    assert(!result.success);
    assertCalls(&state, expected, sizeof(expected) / sizeof(expected[0]));
    assert(state.identityChecks == 4);
}

static void test_invalid_parameters_do_nothing(void) {
    FakeState state = {0};
    VDTPolicyOperations ops = operations(&state);

    assert(!VDTApplyPolicyTransition(0, VDTPolicyModeThrottle, 80, 120, &ops).success);
    assert(!VDTApplyPolicyTransition(42, VDTPolicyModeThrottle, 0, 120, &ops).success);
    assert(!VDTApplyPolicyTransition(42, VDTPolicyModeFatal, 80, 0, &ops).success);
    assert(state.callCount == 0);
    assert(state.identityChecks == 0);
}

int main(void) {
    test_throttle_success();
    test_fatal_success();
    test_retirement_failure_blocks_new_policy();
    test_identity_is_checked_before_each_syscall();
    test_fatal_set_failure_is_not_resumed();
    test_restore_stops_if_identity_changes();
    test_restore_is_best_effort();
    test_invalid_parameters_do_nothing();
    puts("policy transition tests passed");
    return 0;
}
