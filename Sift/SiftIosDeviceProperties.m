// Copyright (c) 2016 Sift Science. All rights reserved.

#if !TARGET_OS_MACCATALYST
@import CoreTelephony;
#endif
@import Foundation;
@import UIKit;

#include <sys/sysctl.h>
#include <sys/stat.h>

#include <mach-o/dyld.h>

#import "SiftCompatibility.h"
#import "SiftDebug.h"
#import "Sift.h"

#import "SiftIosDeviceProperties.h"

NSMutableDictionary *SFMakeEmptyIosDeviceProperties() {
    return [NSMutableDictionary new];
}

#pragma mark - Device properties collection.

static NSString *SFSysctlReadString(const char *name);
static BOOL SFSysctlReadInt32(const char *name, int32_t *output);
static BOOL SFSysctlReadInt64(const char *name, int64_t *output);

static void rot13(char *p);

static BOOL SFIsUrlSchemeWhitelisted(NSString *targetScheme);

NSMutableDictionary *SFCollectIosDeviceProperties() {
    NSMutableDictionary *iosDeviceProperties = SFMakeEmptyIosDeviceProperties();

    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    [iosDeviceProperties setValue:[infoDictionary objectForKey:(NSString *)kCFBundleNameKey] forKey:@"app_name"];
    [iosDeviceProperties setValue:[infoDictionary objectForKey:(NSString *)kCFBundleVersionKey] forKey:@"app_version"];
    [iosDeviceProperties setValue:[infoDictionary objectForKey:@"CFBundleShortVersionString"] forKey:@"app_version_short"];
    [iosDeviceProperties setValue:[Sift sharedInstance].sdkVersion forKey:@"sdk_version"];

    UIDevice *device = [UIDevice currentDevice];
    [iosDeviceProperties setValue:device.name forKey:@"device_name"];
    [iosDeviceProperties setValue:device.model forKey:@"device_model"];
    [iosDeviceProperties setValue:device.localizedModel forKey:@"device_localized_model"];
    [iosDeviceProperties setValue:device.systemName forKey:@"device_system_name"];
    [iosDeviceProperties setValue:device.systemVersion forKey:@"device_system_version"];
    
    NSUUID *ifa = nil;
    Class ASIdentifierManagerClass = NSClassFromString(@"ASIdentifierManager");
    if (ASIdentifierManagerClass) {
        SEL sharedManagerSelector = NSSelectorFromString(@"sharedManager");
        id sharedManager = ((id (*)(id, SEL))[ASIdentifierManagerClass methodForSelector:sharedManagerSelector])(ASIdentifierManagerClass, sharedManagerSelector);
        SEL advertisingTrackingEnabledSelector = NSSelectorFromString(@"isAdvertisingTrackingEnabled");
        BOOL isTrackingEnabled = ((BOOL (*)(id, SEL))[sharedManager methodForSelector:advertisingTrackingEnabledSelector])(sharedManager, advertisingTrackingEnabledSelector);
        if (isTrackingEnabled) {
            SEL advertisingIdentifierSelector = NSSelectorFromString(@"advertisingIdentifier");
            ifa = ((NSUUID* (*)(id, SEL))[sharedManager methodForSelector:advertisingIdentifierSelector])(sharedManager, advertisingIdentifierSelector);
        }
    }
    
    if (ifa) {  // IFA could be nil.
        [iosDeviceProperties setValue:ifa.UUIDString forKey:@"device_ifa"];
    }
    
    NSUUID *ifv = device.identifierForVendor;
    if (ifv) {  // IFV could be nil.
        [iosDeviceProperties setValue:ifv.UUIDString forKey:@"device_ifv"];
    }

    UIScreen *screen = [UIScreen mainScreen];
    [iosDeviceProperties setValue:[NSNumber numberWithInt:(screen.fixedCoordinateSpace.bounds.size.width * screen.scale)] forKey:@"device_screen_width"];
         [iosDeviceProperties setValue:[NSNumber numberWithInt:(screen.fixedCoordinateSpace.bounds.size.height * screen.scale)] forKey:@"device_screen_height"];

#if !TARGET_OS_MACCATALYST
    CTTelephonyNetworkInfo *networkInfo = [CTTelephonyNetworkInfo new];
    CTCarrier *carrier = [networkInfo subscriberCellularProvider];
    if (carrier) {
        [iosDeviceProperties setValue:carrier.carrierName forKey:@"mobile_carrier_name"];
        [iosDeviceProperties setValue:carrier.isoCountryCode forKey:@"mobile_iso_country_code"];
        [iosDeviceProperties setValue:carrier.mobileCountryCode forKey:@"mobile_country_code"];
        [iosDeviceProperties setValue:carrier.mobileNetworkCode forKey:@"mobile_network_code"];
    }
#endif

    // Simulator detection
#if TARGET_OS_SIMULATOR
    [iosDeviceProperties setValue:[NSNumber numberWithBool:YES] forKey:@"is_simulator"];
#else
    [iosDeviceProperties setValue:[NSNumber numberWithBool:NO] forKey:@"is_simulator"];
#endif

    enum SysctlType {
        SYSCTL_INT32,
        SYSCTL_INT64,
        SYSCTL_STRING,
    };
    enum SysctlInt32Conversion {
        SYSCTL_TO_NONE,
        SYSCTL_TO_BOOL,
        SYSCTL_TO_INTEGER,
        SYSCTL_TO_STRING,
    };
    struct SysctlSpec {
        char *entry_key;
        char *sysctl_name;
        enum SysctlType sysctl_type;
        enum SysctlInt32Conversion sysctl_int32_conversion;
    } specs[] = {
        // entry_key                        sysctl_name                     sysctl_type     sysctl_int32_conversion
        {"device_hardware_machine",         "hw.machine",                   SYSCTL_STRING},
        {"device_hardware_model",           "hw.model",                     SYSCTL_STRING},
        {"device_package_count",            "hw.packages",                  SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"device_memory_size",              "hw.memsize",                   SYSCTL_INT64},
        {"device_page_size",                "hw.pagesize",                  SYSCTL_INT64},
        {"device_tb_frequency",             "hw.tbfrequency",               SYSCTL_INT64},
        {"device_kernel_uuid",              "kern.uuid",                    SYSCTL_STRING},
        {"device_kernel_version",           "kern.version",                 SYSCTL_STRING},
        {"device_kernel_boot_session_uuid", "kern.bootsessionuuid",         SYSCTL_STRING},
        {"device_kernel_boot_signature",    "kern.bootsignature",           SYSCTL_STRING},
        {"device_host_id",                  "kern.hostid",                  SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"device_host_name",                "kern.hostname",                SYSCTL_STRING},
        {"device_os_type",                  "kern.ostype",                  SYSCTL_STRING},
        {"device_os_release",               "kern.osrelease",               SYSCTL_STRING},
        {"device_os_revision",              "kern.osrevision",              SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"device_posix1_version",           "kern.posix1version",           SYSCTL_STRING},
        {"device_posix2_version",           "user.posix2_version",          SYSCTL_STRING},
        {"cpu_family",                      "hw.cpufamily",                 SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"cpu_type",                        "hw.cputype",                   SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"cpu_subtype",                     "hw.cpusubtype",                SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"cpu_byte_order",                  "hw.byteorder",                 SYSCTL_INT32,   SYSCTL_TO_STRING},
        {"cpu_64bit_capable",               "hw.cpu64bit_capable",          SYSCTL_INT32,   SYSCTL_TO_BOOL},
        {"cpu_has_fp",                      "hw.optional.floatingpoint",    SYSCTL_INT32,   SYSCTL_TO_BOOL},
        {"cpu_count",                       "hw.ncpu",                      SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"cpu_physical_cpu_count",          "hw.physicalcpu",               SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"cpu_physical_cpu_max",            "hw.physicalcpu_max",           SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"cpu_logical_cpu_count",           "hw.logicalcpu",                SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"cpu_logical_cpu_max",             "hw.logicalcpu_max",            SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"cpu_active_cpu_count",            "hw.activecpu",                 SYSCTL_INT32,   SYSCTL_TO_INTEGER},
        {"cpu_frequency",                   "hw.cpufrequency",              SYSCTL_INT64},
        {"cpu_frequency_min",               "hw.cpufrequency_min",          SYSCTL_INT64},
        {"cpu_frequency_max",               "hw.cpufrequency_max",          SYSCTL_INT64},
        {"cache_line_size",                 "hw.cachelinesize",             SYSCTL_INT64},
        {"cache_l1_dcache_size",            "hw.l1dcachesize",              SYSCTL_INT64},
        {"cache_l1_icache_size",            "hw.l1icachesize",              SYSCTL_INT64},
        {"cache_l2_cache_size",             "hw.l2cachesize",               SYSCTL_INT64},
        {"cache_l3_cache_size",             "hw.l3cachesize",               SYSCTL_INT64},
        {"bus_frequency",                   "hw.busfrequency",              SYSCTL_INT64},
        {"bus_frequency_min",               "hw.busfrequency_min",          SYSCTL_INT64},
        {"bus_frequency_max",               "hw.busfrequency_max",          SYSCTL_INT64},
    };
    for (int i = 0; i < sizeof(specs) / sizeof(specs[0]); i++) {
        struct SysctlSpec *spec = specs + i;
        id value = nil;
        switch (spec->sysctl_type) {
            case SYSCTL_INT32:
            {
                int32_t buffer;
                if (SFSysctlReadInt32(spec->sysctl_name, &buffer)) {
                    switch (spec->sysctl_int32_conversion) {
                        case SYSCTL_TO_BOOL:
                            value = [NSNumber numberWithBool:buffer];
                            break;
                        case SYSCTL_TO_INTEGER:
                            value = [NSNumber numberWithLong:buffer];
                            break;
                        case SYSCTL_TO_STRING:
                            value = [NSString stringWithFormat:@"%ld", (long)buffer];
                            break;
                        default:
                            SF_DEBUG(@"Unknown conversion: %d", spec->sysctl_int32_conversion);
                    }
                }
                break;
            }
            case SYSCTL_INT64:
            {
                int64_t buffer;
                if (SFSysctlReadInt64(spec->sysctl_name, &buffer)) {
                    value = [NSNumber numberWithLongLong:buffer];
                }
                break;
            }
            case SYSCTL_STRING:
                value = SFSysctlReadString(spec->sysctl_name);
                break;
            default:
                SF_DEBUG(@"Unknown type: %d", spec->sysctl_type);
        }
        if (value) {
            [iosDeviceProperties setValue:value forKey:[NSString stringWithUTF8String:spec->entry_key]];
        }
    }

    /*
     * Collect properties for detecting whether this device is jail broken.
     *
     * The detections implemented here are from public sources, meaning a
     * determined jail breaker should know and be able to patch around all
     * of them.
     *
     * NOTE: Don't leave "obvious" string constants or exposed symbol names
     * like "jail broken" in the compiled binary - this would make reverse
     * engineer's job slightly harder of finding the detection code with
     * simple full text search (and patching around it).
     */

    // 1. Filesystem-based detection.

    // Files that are typical to a jail-broken device, which are ROT13
    // encoded to hide from simple full text search - it can't stop a
    // determined mind but could slow it down a bit.
    char paths[] = \
    "/cevingr/ine/fgnfu\n"
    "/cevingr/ine/yvo/ncg\n"
    "/cevingr/ine/gzc/plqvn.ybt\n"
    "/cevingr/ine/yvo/plqvn\n"
    "/cevingr/ine/zbovyr/Yvoenel/FOFrggvatf/Gurzrf\n"
    "/Yvoenel/ZbovyrFhofgengr/ZbovyrFhofgengr.qlyvo\n"
    "/Yvoenel/ZbovyrFhofgengr/QlanzvpYvoenevrf/Irrapl.cyvfg\n"
    "/Yvoenel/ZbovyrFhofgengr/QlanzvpYvoenevrf/YvirPybpx.cyvfg\n"
    "/Flfgrz/Yvoenel/YnhapuQnrzbaf/pbz.vxrl.oobg.cyvfg\n"
    "/Flfgrz/Yvoenel/YnhapuQnrzbaf/pbz.fnhevx.Plqvn.Fgneghc.cyvfg\n"
    "/ine/pnpur/ncg\n"
    "/ine/yvo/ncg\n"
    "/ine/yvo/plqvn\n"
    "/ine/ybt/flfybt\n"
    "/ine/gzc/plqvn.ybt\n"
    "/ova/onfu\n"
    "/ova/fu\n"
    "/hfe/fova/ffuq\n"
    "/hfe/yvorkrp/ffu-xrlfvta\n"
    "/hfe/fova/ffuq\n"
    "/hfe/ova/ffuq\n"
    "/hfe/yvorkrp/fsgc-freire\n"
    "/rgp/ffu/ffuq_pbasvt\n"
    "/rgp/ncg\n"
    "/Nccyvpngvbaf/Plqvn.ncc\n"
    "/Nccyvpngvbaf/EbpxNcc.ncc\n"
    "/Nccyvpngvbaf/Vpl.ncc\n"
    "/Nccyvpngvbaf/JvagreObneq.ncc\n"
    "/Nccyvpngvbaf/FOFrggvatf.ncc\n"
    "/Nccyvpngvbaf/ZkGhor.ncc\n"
    "/Nccyvpngvbaf/VagryyvFperra.ncc\n"
    "/Nccyvpngvbaf/SnxrPneevre.ncc\n"
    "/Nccyvpngvbaf/oynpxen1a.ncc\n"
    "/Nccyvpngvbaf/oynpxfa0j.ncc\n"
    "/Nccyvpngvbaf/terracbvf0a.ncc\n"
    "/Nccyvpngvbaf/yvzren1a.ncc\n"
    "/Nccyvpngvbaf/erqfa0j.ncc\n";
    rot13(paths);

    SF_GENERICS(NSMutableArray, NSString *) *filesPresent = [NSMutableArray new];
    for (char *cpath = paths, *end; (end = strchr(cpath, '\n')) != NULL; cpath = end + 1) {
        *end = '\0';
        if (!access(cpath, F_OK)) {
            SF_DEBUG(@"Found file: \"%s\"", cpath);
            NSString *path = [NSString stringWithCString:cpath encoding:NSASCIIStringEncoding];
            [filesPresent addObject:path];
        }
    }
    [iosDeviceProperties setValue:filesPresent forKey:@"evidence_files_present"];

    // Dirs that should not be writable nor symlinks. (ROT-13 encoded)
    char dirs[] = \
    "/\n"
    "/Yvoenel/Evatgbarf\n"
    "/Yvoenel/Jnyycncre\n"
    "/cevingr\n"
    "/hfe/nez-nccyr-qnejva9\n"
    "/hfe/vapyhqr\n"
    "/hfe/yvorkrp\n"
    "/hfe/funer\n"
    "/Nccyvpngvbaf\n";
    rot13(dirs);

    SF_GENERICS(NSMutableArray, NSString *) *dirsSymlinked = [NSMutableArray new];
    SF_GENERICS(NSMutableArray, NSString *) *dirsWritable = [NSMutableArray new];
    for (char *cpath = dirs, *end; (end = strchr(cpath, '\n')) != NULL; cpath = end + 1) {
        *end = '\0';
        struct stat dirStat;
        if (!lstat(cpath, &dirStat)) {
            NSString *path = [NSString stringWithCString:cpath encoding:NSASCIIStringEncoding];
            if (S_ISLNK(dirStat.st_mode)) {
                SF_DEBUG(@"\"%@\" is a symlink", path);
                [dirsSymlinked addObject:path];
            }
            if (dirStat.st_mode & S_IWOTH) {
                SF_DEBUG(@"\"%@\" is writable by others", path);
                [dirsWritable addObject:path];
            }
        }
    }
    [iosDeviceProperties setValue:dirsSymlinked forKey:@"evidence_directories_symlinked"];
    [iosDeviceProperties setValue:dirsWritable forKey:@"evidence_directories_writable"];

    // 2. dyld detection.

    SF_GENERICS(NSMutableArray, NSString *) *dyldsPresent = [NSMutableArray new];

    char dyldname[] = "ZbovyrFhofgengr";  // "MobileSubstrate"
    rot13(dyldname);

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *cdyld = _dyld_get_image_name(i);
        if (strstr(cdyld, dyldname)) {
            NSString *dyld = [NSString stringWithCString:cdyld encoding:NSASCIIStringEncoding];
            SF_DEBUG(@"Found dyld: \"%@\"", dyld);
            [dyldsPresent addObject:dyld];
        }
    }

    [iosDeviceProperties setValue:dyldsPresent forKey:@"evidence_dylds_present"];

    // 3. Cydia URL scheme detection.

    // Because when we poke iOS about this, it reports an error, and
    // that sometimes confuses SDK users, we will only poke once per
    // process.
    static SF_GENERICS(NSMutableArray, NSString *) *urlSchemesOpenable = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char cscheme[] = "plqvn";  // "cydia"
        rot13(cscheme);
        NSString *scheme = [NSString stringWithCString:cscheme encoding:NSASCIIStringEncoding];

        if (!SFIsUrlSchemeWhitelisted(scheme)) {
            SF_DEBUG(@"URL scheme not whitelisted: %@", scheme);
            return;
        }

        urlSchemesOpenable = [NSMutableArray new];

        char curlpath[] = "://cnpxntr/pbz.rknzcyr.cnpxntr";  // "://package/com.example.package"
        rot13(curlpath);
        NSString *urlpath = [NSString stringWithCString:curlpath encoding:NSASCIIStringEncoding];
        NSString *url = [scheme stringByAppendingString:urlpath];

        SF_DEBUG(@"Check URL scheme %@", scheme);
        if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:url]]) {
            SF_DEBUG(@"Can open URL: %@", url);
            [urlSchemesOpenable addObject:scheme];
        }
    });

    if (urlSchemesOpenable) {
        [iosDeviceProperties setValue:urlSchemesOpenable forKey:@"evidence_url_schemes_openable"];
    }

    return iosDeviceProperties;
}

#pragma mark - Helper functions.

static NSString *SFSysctlReadString(const char *name) {
    int err;
    size_t size;
    err = sysctlbyname(name, NULL, &size, NULL, 0);
    if (err) {
        SF_DEBUG(@"sysctlbyname(\"%s\", ...): %s", name, strerror(errno));
        return nil;
    }

    NSString *value = nil;
    char buffer[64];
    void *buf = size < sizeof(buffer) ? buffer : malloc(size);
    err = sysctlbyname(name, buf, &size, NULL, 0);
    if (err) {
        SF_DEBUG(@"sysctlbyname(\"%s\", ...): %s", name, strerror(errno));
    } else {
        value = [NSString stringWithCString:buf encoding:NSUTF8StringEncoding];
    }
    if (buf != buffer) {
        free(buf);
    }
    return value;
}

static BOOL SFSysctlReadInt32(const char *name, int32_t *output) {
    size_t size = sizeof(*output);
    int err = sysctlbyname(name, output, &size, NULL, 0);
    if (err) {
        SF_DEBUG(@"sysctlbyname(\"%s\", ...): %s", name, strerror(errno));
        return NO;
    } else {
        return YES;
    }
}

static BOOL SFSysctlReadInt64(const char *name, int64_t *output) {
    size_t size = sizeof(*output);
    int err = sysctlbyname(name, output, &size, NULL, 0);
    if (err) {
        SF_DEBUG(@"sysctlbyname(\"%s\", ...): %s", name, strerror(errno));
        return NO;
    } else {
        return YES;
    }
}

static void rot13(char *p) {
    while (*p) {
        if (isalpha(*p)) {
            char alpha = islower(*p) ? 'a' : 'A';
            *p = (*p - alpha + 13) % 26 + alpha;
        }
        p++;
    }
}

static BOOL SFIsUrlSchemeWhitelisted(NSString *targetScheme) {
    // NOTE: To test this whitelist check, you have to switch deployment
    // target to iOS 9+.
    // NOTE: Use `90000` instead of `__IPHONE_9_0` since older SDK
    // bundled with Xcode 6 does not have `__IPHONE_9_0`.
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 90000
    // iOS 9 requires white-listing URL schemes.
    NSDictionary *infos = [[NSBundle mainBundle] infoDictionary];
    NSArray *schemes = [infos objectForKey:@"LSApplicationQueriesSchemes"];
    if (!schemes) {
        SF_DEBUG(@"Did not find LSApplicationQueriesSchemes");
        return NO;
    }
    for (NSString *scheme in schemes) {
        SF_DEBUG(@"Whitelist scheme: %@", scheme);
        if ([scheme isEqualToString:targetScheme]) {
            return YES;
        }
    }
    return NO;
#else
    return YES;
#endif
}
