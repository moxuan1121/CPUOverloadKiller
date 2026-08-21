#import "Common.h"
#import "VDTShared.h"
#import <UIKit/UIKit.h>
#include <libproc/libproc.h>
#include <libproc/libproc_internal.h>
#include <mach/mach_time.h>
#include <notify.h>
#include <signal.h>
#include <time.h>

static const uint64_t NSSEC = 1000000000ULL;
static dispatch_queue_t queue;
static dispatch_source_t timer;
static int prefsToken = -1;
static NSString *frontmostID;
static uint64_t nextDiscovery;
static uint64_t discoveryDelay = 5ULL * 1000000000ULL;
static BOOL configsDirty = YES;

@interface SpringBoard : UIApplication
- (id)_accessibilityFrontMostApplication;
@end
@interface NSObject (GCGApp)
- (NSString *)bundleIdentifier;
@end

typedef struct { uint8_t uuid[16]; uint64_t userTime, systemTime, packageIdleWakeups,
interruptWakeups, pageins, wiredSize, residentSize, physicalFootprint,
processStartAbsoluteTime, processExitAbsoluteTime; } gcg_rusage_info_v0;

@interface GCGState : NSObject
@property(copy) NSString *identifier;
@property VDTConfigType type;
@property BOOL background;
@property NSUInteger threshold, duration, idle, nearThreshold, nearSample, exceedSample;
@property pid_t pid;
@property(copy) NSString *path;
@property(copy) NSString *expectedPath;
@property uint64_t start, oldCPU, oldWall, exceeded, due;
@property BOOL exceeding;
@property int statusToken;
@property(nonatomic,strong) dispatch_source_t exitSource;
@end
@implementation GCGState
- (instancetype)init { if((self=[super init]))_statusToken=-1;return self; }
- (void)dealloc { if(_statusToken>=0)notify_cancel(_statusToken); }
@end
static NSMutableDictionary<NSString *, GCGState *> *states;
static void schedule(uint64_t delay);
static void reset_discovery(void){nextDiscovery=0;discoveryDelay=5*NSSEC;}

static uint64_t now_ns(void) { struct timespec t={0}; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*NSSEC+t.tv_nsec; }
static double ticks_ns(uint64_t ticks) {
    static mach_timebase_info_data_t tb; static dispatch_once_t once;
    dispatch_once(&once, ^{ if (mach_timebase_info(&tb)!=KERN_SUCCESS||!tb.numer||!tb.denom) tb.numer=tb.denom=1; });
    return (double)ticks*tb.numer/tb.denom;
}
static NSString *key_for(VDTConfigType type, NSString *identifier) { return [NSString stringWithFormat:@"%lu:%@",(unsigned long)type,identifier]; }
static NSInteger valid(id value, NSInteger fallback, NSInteger low, NSInteger high) {
    NSInteger n=[value respondsToSelector:@selector(integerValue)]?[value integerValue]:fallback; return n<low||n>high?fallback:n;
}
static NSString *pid_path(pid_t pid) { char b[PROC_PIDPATHINFO_MAXSIZE]={0}; return pid>0&&proc_pidpath(pid,b,sizeof(b))>0?[NSString stringWithUTF8String:b]:nil; }
static NSString *pid_name(pid_t pid) { char b[256]={0}; return pid>0&&proc_name(pid,b,sizeof(b))>0?[NSString stringWithUTF8String:b]:nil; }
static NSString *bundle_for_path(NSString *path) {
    NSRange r=[path rangeOfString:@".app/" options:NSBackwardsSearch]; if(r.location==NSNotFound)return nil;
    NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[[path substringToIndex:r.location+4] stringByAppendingPathComponent:@"Info.plist"]];
    return [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class]?info[@"CFBundleIdentifier"]:nil;
}
static BOOL usage(pid_t pid,uint64_t *cpu,uint64_t *start) {
    gcg_rusage_info_v0 u={}; if(pid<=0||proc_pid_rusage(pid,RUSAGE_INFO_V0,&u)!=0||!u.processStartAbsoluteTime)return NO;
    if(cpu)*cpu=u.userTime+u.systemTime; if(start)*start=u.processStartAbsoluteTime; return YES;
}
static void publish(GCGState *s,AwemeCPUGuardStatus status,double cpu,double exceeded) {
    NSString *name=GCGStatusNotificationName(s.type,s.identifier);
    if(s.statusToken<0){int token=-1;if(notify_register_check(name.UTF8String,&token)!=NOTIFY_STATUS_OK)return;s.statusToken=token;}
    notify_set_state(s.statusToken,AwemeCPUGuardEncodeStatus(status,(NSUInteger)MAX(0,MIN(cpu*10,16777215)),s.threshold,(NSUInteger)MAX(0,MIN(exceeded*10,65535))));
}
static void clear_state(GCGState *s) { if(s.exitSource){dispatch_source_cancel(s.exitSource);s.exitSource=nil;}s.pid=0;s.path=nil;s.start=0;s.oldCPU=0;s.oldWall=0;s.exceeded=0;s.exceeding=NO;s.due=0; }
static void bind_state(GCGState *s,pid_t pid,NSString *path,uint64_t start,uint64_t now){s.pid=pid;s.path=path;s.start=start;s.due=now;
    dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,(uintptr_t)pid,DISPATCH_PROC_EXIT,queue);s.exitSource=source;
    dispatch_source_set_event_handler(source,^{if(s.pid==pid){clear_state(s);publish(s,AwemeCPUGuardStatusWaitingForProcess,0,0);reset_discovery();schedule(NSEC_PER_MSEC*100);}});dispatch_resume(source);}
static BOOL same_instance(GCGState *s) {
    NSString *path=pid_path(s.pid);uint64_t start=0;
    return path.length&&[path isEqual:s.path]&&usage(s.pid,NULL,&start)&&start==s.start;
}
static BOOL identity(GCGState *s) {
    if(!same_instance(s))return NO;NSString *path=s.path;
    return s.type==VDTConfigTypeApp?[(bundle_for_path(path)?:@"") isEqualToString:s.identifier]:
        ([(pid_name(s.pid)?:@"") isEqualToString:s.identifier]&&(!s.expectedPath.length||[path isEqualToString:s.expectedPath]));
}
static BOOL allowed(GCGState *s) { return s.type==VDTConfigTypeDaemon||s.background||[frontmostID isEqual:s.identifier]; }

static void sync_configs(void) {
    NSDictionary *prefs=getPrefs()?:@{};BOOL master=prefs[@"enabled"]?[prefs[@"enabled"] boolValue]:YES;NSMutableSet *keep=[NSMutableSet set];
    NSArray *defs=@[@[@(VDTConfigTypeApp),@"appConfigs",@"bundleIdentifier"],@[@(VDTConfigTypeDaemon),@"daemonConfigs",@"daemonName"]];
    for(NSArray *def in defs){VDTConfigType type=[def[0] unsignedIntegerValue];NSArray *list=[prefs[def[1]] isKindOfClass:NSArray.class]?prefs[def[1]]:@[];
        for(NSDictionary *config in list){if(![config isKindOfClass:NSDictionary.class])continue;NSString *identifier=config[def[2]];
            if(!master||!identifier.length||![config[@"enabled"] boolValue]||GCGIdentifierIsProtected(identifier))continue;
            NSString *key=key_for(type,identifier);[keep addObject:key];GCGState *s=states[key];BOOL created=!s;if(created){s=[GCGState new];s.identifier=identifier;s.type=type;states[key]=s;}
            s.threshold=valid(config[@"cpuThreshold"],80,2,1000);s.duration=valid(config[@"durationSeconds"],10,1,3600);s.idle=valid(config[@"idleSampleSeconds"],60,1,3600);s.nearThreshold=valid(config[@"nearThresholdPercent"],(s.threshold*2)/3,1,s.threshold-1);s.nearSample=valid(config[@"nearSampleSeconds"],15,1,3600);s.exceedSample=valid(config[@"exceedSampleSeconds"],1,1,s.duration);s.expectedPath=[config[@"executablePath"] isKindOfClass:NSString.class]?config[@"executablePath"]:nil;
            s.background=type==VDTConfigTypeDaemon||[config[@"monitorInBackground"] boolValue];if(created)publish(s,(type==VDTConfigTypeApp&&!s.background&&![frontmostID isEqual:identifier])?AwemeCPUGuardStatusWaitingForForeground:AwemeCPUGuardStatusWaitingForProcess,0,0);}}
    for(NSString *key in states.allKeys.copy)if(![keep containsObject:key]){GCGState *s=states[key];publish(s,AwemeCPUGuardStatusDisabled,0,0);clear_state(s);[states removeObjectForKey:key];}
}
static void discover(uint64_t now) {
    BOOL missing=NO;for(GCGState *s in states.allValues)if(!s.pid&&(s.type==VDTConfigTypeDaemon||s.background||[frontmostID isEqual:s.identifier])){missing=YES;break;}if(!missing||now<nextDiscovery)return;
    nextDiscovery=now+discoveryDelay;BOOL bound=NO;
    int bytes=proc_listpids(PROC_ALL_PIDS,0,NULL,0);if(bytes<=0)return;int *pids=(int *)calloc(1,(size_t)bytes);if(!pids)return;int count=proc_listpids(PROC_ALL_PIDS,0,pids,bytes)/(int)sizeof(int);
    for(int i=0;i<count;i++){pid_t pid=pids[i];NSString *path=pid_path(pid);if(!path.length)continue;NSString *name=nil,*bundle=nil;
        for(GCGState *s in states.allValues){if(s.pid||(s.type==VDTConfigTypeApp&&!s.background&&![frontmostID isEqual:s.identifier]))continue;BOOL match=NO;if(s.type==VDTConfigTypeDaemon){if(!name)name=pid_name(pid);match=[name isEqual:s.identifier]&&(!s.expectedPath.length||[path isEqual:s.expectedPath]);}else{if(!bundle)bundle=bundle_for_path(path);match=[bundle isEqual:s.identifier];}
            uint64_t start=0;if(match&&usage(pid,NULL,&start)){bind_state(s,pid,path,start,now);publish(s,AwemeCPUGuardStatusMonitoring,0,0);bound=YES;}}}free(pids);
    discoveryDelay=bound?5*NSSEC:MIN(discoveryDelay*2,60*NSSEC);
}
static void sample(GCGState *s,uint64_t now) {
    if(!same_instance(s)){clear_state(s);publish(s,AwemeCPUGuardStatusWaitingForProcess,0,0);return;}
    if(!allowed(s)){s.oldCPU=s.oldWall=s.exceeded=0;s.exceeding=NO;s.due=now+s.idle*NSSEC;publish(s,AwemeCPUGuardStatusWaitingForForeground,0,0);return;}
    uint64_t cpu=0;if(!usage(s.pid,&cpu,NULL)){clear_state(s);publish(s,AwemeCPUGuardStatusCPUReadFailed,0,0);return;}
    if(!s.oldWall||now<=s.oldWall||cpu<s.oldCPU){s.oldCPU=cpu;s.oldWall=now;s.due=now+NSSEC;publish(s,AwemeCPUGuardStatusMonitoring,0,0);return;}
    uint64_t wall=now-s.oldWall;double percent=ticks_ns(cpu-s.oldCPU)*100.0/wall;s.oldCPU=cpu;s.oldWall=now;
    if(percent>=s.threshold){if(s.exceeding)s.exceeded+=wall;else{s.exceeding=YES;s.exceeded=0;}double seconds=(double)s.exceeded/NSSEC;publish(s,AwemeCPUGuardStatusThresholdExceeded,percent,seconds);
        if(s.exceeded>=s.duration*NSSEC&&allowed(s)&&identity(s)){int result=kill(s.pid,SIGKILL);publish(s,result==0?AwemeCPUGuardStatusKilled:AwemeCPUGuardStatusKillFailed,percent,seconds);clear_state(s);return;}s.due=now+s.exceedSample*NSSEC;
    }else{s.exceeding=NO;s.exceeded=0;publish(s,AwemeCPUGuardStatusMonitoring,percent,0);s.due=now+(percent>=s.nearThreshold?s.nearSample*NSSEC:s.idle*NSSEC);}
}
static void schedule(uint64_t delay){if(timer)dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)MAX(delay,NSEC_PER_MSEC*100)),DISPATCH_TIME_FOREVER,NSEC_PER_MSEC*50);}
static void park_timer(void){if(timer)dispatch_source_set_timer(timer,DISPATCH_TIME_FOREVER,DISPATCH_TIME_FOREVER,0);}
static void run_guard(void){if(configsDirty){sync_configs();configsDirty=NO;}uint64_t now=now_ns();discover(now);uint64_t next=UINT64_MAX;
    for(GCGState *s in states.allValues){if(s.pid&&s.due<=now)sample(s,now);uint64_t due=0;if(s.pid)due=s.due;else if(s.type==VDTConfigTypeDaemon||s.background||[frontmostID isEqual:s.identifier])due=nextDiscovery;if(due&&due<next)next=due;}
    if(next==UINT64_MAX){park_timer();return;}schedule(next>now?next-now:NSEC_PER_MSEC*100);}
static NSString *frontmost_on_main(void){if(!NSThread.isMainThread)return nil;UIApplication *sb=UIApplication.sharedApplication;if(![sb respondsToSelector:@selector(_accessibilityFrontMostApplication)])return nil;id app=[(SpringBoard*)sb _accessibilityFrontMostApplication];return [app respondsToSelector:@selector(bundleIdentifier)]?[app bundleIdentifier]:nil;}

%hook SpringBoard
-(void)frontDisplayDidChange:(id)value{%orig;NSString *identifier=[frontmost_on_main() copy];if(queue)dispatch_async(queue,^{frontmostID=identifier;reset_discovery();for(GCGState *s in states.allValues)if(s.type==VDTConfigTypeApp)s.due=0;schedule(NSEC_PER_MSEC*100);});}
%end
%ctor{@autoreleasepool{if(![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"])return;dispatch_async(dispatch_get_main_queue(),^{NSString *front=[frontmost_on_main() copy];queue=dispatch_queue_create("com.moxuan.cpuoverloadkiller.monitor",DISPATCH_QUEUE_SERIAL);states=[NSMutableDictionary dictionary];frontmostID=front;timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);dispatch_source_set_event_handler(timer,^{@autoreleasepool{run_guard();}});schedule(NSSEC);dispatch_resume(timer);notify_register_dispatch(PREFS_CHANGED_NN.UTF8String,&prefsToken,queue,^(int token){configsDirty=YES;reset_discovery();for(GCGState *s in states.allValues)s.due=0;schedule(NSEC_PER_MSEC*100);});});}}
