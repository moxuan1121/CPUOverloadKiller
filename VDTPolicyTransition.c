#include "VDTPolicyTransition.h"

static VDTPolicyTransitionResult emptyResult(void) {
    VDTPolicyTransitionResult result = {
        .success = false,
        .identityRejected = false,
        .retirementFailed = false,
        .clearResult = VDT_POLICY_OPERATION_NOT_ATTEMPTED,
        .disableResult = VDT_POLICY_OPERATION_NOT_ATTEMPTED,
        .defaultsResult = VDT_POLICY_OPERATION_NOT_ATTEMPTED,
        .resumeResult = VDT_POLICY_OPERATION_NOT_ATTEMPTED,
        .applyResult = VDT_POLICY_OPERATION_NOT_ATTEMPTED,
    };
    return result;
}

static bool identityIsCurrent(pid_t pid,
                              const VDTPolicyOperations *operations,
                              VDTPolicyTransitionResult *result) {
    if (!operations->identityCurrent(pid, operations->context)) {
        result->identityRejected = true;
        return false;
    }
    return true;
}

VDTPolicyTransitionResult VDTApplyPolicyTransition(pid_t pid,
                                                   VDTPolicyMode mode,
                                                   int percentage,
                                                   int interval,
                                                   const VDTPolicyOperations *operations) {
    VDTPolicyTransitionResult result = emptyResult();
    if (pid <= 0 || !operations || !operations->identityCurrent) {
        return result;
    }

    if (mode == VDTPolicyModeThrottle) {
        if (percentage <= 0 || !operations->disableCpuMonitor ||
            !operations->setThrottle) {
            return result;
        }

        // Clear any previous per-thread monitor. Unlike the fatal policy,
        // the task-wide throttle does not need (and must not have) a per-thread
        // monitor re-enabled, because the per-thread default limit caps each
        // thread individually before the aggregate throttle can act.
        if (!identityIsCurrent(pid, operations, &result)) return result;
        result.disableResult = operations->disableCpuMonitor(pid, operations->context);
        if (result.disableResult != 0) {
            result.retirementFailed = true;
            return result;
        }

        if (!identityIsCurrent(pid, operations, &result)) return result;
        result.applyResult = operations->setThrottle(pid, percentage, operations->context);
        result.success = result.applyResult == 0;
        return result;
    }

    if (mode == VDTPolicyModeFatal) {
        if (percentage <= 0 || interval <= 0 || !operations->clearCpuLimits ||
            !operations->disableCpuMonitor || !operations->setFatal ||
            !operations->resumeCpuMonitor) {
            return result;
        }

        if (!identityIsCurrent(pid, operations, &result)) return result;
        result.clearResult = operations->clearCpuLimits(pid, operations->context);
        if (result.clearResult != 0) {
            result.retirementFailed = true;
            return result;
        }

        if (!identityIsCurrent(pid, operations, &result)) return result;
        result.disableResult = operations->disableCpuMonitor(pid, operations->context);
        if (result.disableResult != 0) {
            result.retirementFailed = true;
            return result;
        }

        if (!identityIsCurrent(pid, operations, &result)) return result;
        result.applyResult = operations->setFatal(pid, percentage, interval, operations->context);
        if (result.applyResult != 0) return result;

        if (!identityIsCurrent(pid, operations, &result)) return result;
        result.resumeResult = operations->resumeCpuMonitor(pid, operations->context);
        result.success = result.resumeResult == 0;
        return result;
    }

    if (mode != VDTPolicyModeRestore || !operations->clearCpuLimits ||
        !operations->disableCpuMonitor || !operations->setCpuMonitorDefaults ||
        !operations->resumeCpuMonitor) {
        return result;
    }

    if (!identityIsCurrent(pid, operations, &result)) return result;
    result.clearResult = operations->clearCpuLimits(pid, operations->context);

    if (!identityIsCurrent(pid, operations, &result)) return result;
    result.disableResult = operations->disableCpuMonitor(pid, operations->context);

    if (!identityIsCurrent(pid, operations, &result)) return result;
    result.defaultsResult = operations->setCpuMonitorDefaults(pid, operations->context);

    if (!identityIsCurrent(pid, operations, &result)) return result;
    result.resumeResult = operations->resumeCpuMonitor(pid, operations->context);

    result.success = result.clearResult == 0 && result.disableResult == 0 &&
        result.defaultsResult == 0 && result.resumeResult == 0;
    return result;
}
