#ifndef VDT_POLICY_TRANSITION_H
#define VDT_POLICY_TRANSITION_H

#include <stdbool.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VDT_POLICY_OPERATION_NOT_ATTEMPTED (-2147483647 - 1)

typedef enum {
    VDTPolicyModeRestore = 0,
    VDTPolicyModeFatal = 2,
    VDTPolicyModeThrottle = 3,
} VDTPolicyMode;

typedef bool (*VDTPolicyIdentityOperation)(pid_t pid, void *context);
typedef int (*VDTPolicyPidOperation)(pid_t pid, void *context);
typedef int (*VDTPolicyThrottleOperation)(pid_t pid, int percentage, void *context);
typedef int (*VDTPolicyFatalOperation)(pid_t pid,
                                       int percentage,
                                       int interval,
                                       void *context);

typedef struct {
    VDTPolicyIdentityOperation identityCurrent;
    VDTPolicyPidOperation clearCpuLimits;
    VDTPolicyPidOperation disableCpuMonitor;
    VDTPolicyPidOperation setCpuMonitorDefaults;
    VDTPolicyPidOperation resumeCpuMonitor;
    VDTPolicyThrottleOperation setThrottle;
    VDTPolicyFatalOperation setFatal;
    void *context;
} VDTPolicyOperations;

typedef struct {
    bool success;
    bool identityRejected;
    bool retirementFailed;
    int clearResult;
    int disableResult;
    int defaultsResult;
    int resumeResult;
    int applyResult;
} VDTPolicyTransitionResult;

// Applies one policy transition while treating process identity and retirement
// of the prior policy as hard gates. Restore remains best-effort: it attempts
// every cleanup operation while the same process instance is still current.
VDTPolicyTransitionResult VDTApplyPolicyTransition(pid_t pid,
                                                   VDTPolicyMode mode,
                                                   int percentage,
                                                   int interval,
                                                   const VDTPolicyOperations *operations);

#ifdef __cplusplus
}
#endif

#endif
