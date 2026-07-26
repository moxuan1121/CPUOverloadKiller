//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTShared.h"

#include <libproc/libproc.h>
#include <libproc/libproc_internal.h>

#ifdef __cplusplus
extern "C" {
#endif

// Thread-safe prefs accessors. Use instead of direct global access.
void VDTSetPrefs(NSDictionary *newPrefs);
NSDictionary *VDTGetPrefs(void);

// Keys of a normalised config entry (vdt_configs_from_prefs) and of a resolved
// target (vdt_resolve_targets / vdt_targets_for_pid).
extern NSString * const VDTConfigIdentifierKey;
extern NSString * const VDTConfigTypeKey;
extern NSString * const VDTConfigPercentageKey;
extern NSString * const VDTConfigIntervalKey;
extern NSString * const VDTConfigPolicyKey;
extern NSString * const VDTConfigEnabledKey;
extern NSString * const VDTTargetPidKey;
extern NSString * const VDTTargetNameKey;
extern NSString * const VDTTargetExecutablePathKey;
extern NSString * const VDTTargetProcCommKey;

// Type-checked normalisation of the user-writable prefs plist. Entries without a
// valid identifier are dropped; entries with malformed parameters are retained
// as disabled so a reload can undo limits previously applied by Vedette. The
// global switch is folded into each entry's enabled flag.
NSArray<NSDictionary *>* vdt_configs_from_prefs(NSDictionary *prefs);

// Scans running processes and returns one target per configured process that is
// currently alive. Each target carries its own percentage/interval/policy, so
// there are no parallel arrays to keep aligned.
NSArray<NSDictionary *>* vdt_resolve_targets(NSArray<NSDictionary *> *configs);

// Same resolution for a single PID. Returns an empty array when the process is
// not configured, which means "leave it alone".
NSArray<NSDictionary *>* vdt_targets_for_pid(pid_t pid, NSArray<NSDictionary *> *configs);

// Applies each target's own settings. A target with policy None or a zero
// percentage/interval is restored to system defaults instead of limited.
void vdt_apply_targets(NSArray<NSDictionary *> *targets);

void received_new_proc(pid_t pid);

#ifdef __cplusplus
}
#endif
