// AIMOLCore.dylib v3 - AI Modder Online (iOS arm64, Objective-C++)
//
// QUY TẮC CHO FILE .mm (đã từng gây lỗi biên dịch):
//   - `new`, `class`, `delete`, `this` là từ khóa C++ => KHÔNG viết Foo.new / Foo.class.
//     Luôn dùng [[Foo alloc] init] và [Foo class].
//   - Không dùng hằng CGPointZero/UIEdgeInsetsZero; dùng CGPointMake(0, 0)/UIEdgeInsetsMake(0, 0, 0, 0).
//   - C++ không tự ép int -> enum; khi OR các enum phải ép kiểu tường minh.
//
// THIẾT KẾ:
//   - CHỈ dựng giao diện khi nạp. KHÔNG dump, KHÔNG gọi mạng cho đến khi người dùng bấm nút.
//   - Dump IL2CPP: chỉ chạy khi bấm [DUMP METADATA], trên luồng riêng, ghi thẳng ra file.
//   - Chỉ bắt buộc 11 hàm il2cpp_* cốt lõi; các hàm còn lại là tùy chọn (thiếu thì bỏ bớt thông tin, không lỗi).
//   - Chống sập: nhật ký ghi TRƯỚC khi ghi bộ nhớ/dump, đánh dấu tiến độ dump để lần sau bỏ qua class gây sập,
//     chốt chặn "expect" trước khi ghi, đọc thử bằng vm_read_overwrite (không bao giờ truy cập trực tiếp con trỏ lạ).
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <WebKit/WebKit.h>
#import <PhotosUI/PhotosUI.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <strings.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>

#if __has_include(<dobby.h>)
#import <dobby.h>
#define AIMOL_HAS_DOBBY 1
#endif

#pragma mark - Cấu hình (sửa tại đây nếu cần)

static NSString *const kGeminiModel    = @"gemini-3.8-flash";
static NSString *const kClaudeModel    = @"claude-sonnet-5-5";
static NSString *const kPatchStore     = @"aimol.patches";
static NSString *const kUIStateKey     = @"aimol.ui";
static NSString *const kSkipKey        = @"aimol.dump.skip";
static NSString *const kCacheLockToken = @"aimol.cache.lock";

static const NSUInteger kDumpContextBudget = 14000;  // số ký tự dữ liệu Dump tối đa gửi kèm mỗi câu hỏi
static const NSUInteger kCacheMaxClasses   = 3000;   // số class tối đa trong RAM Cache (class khớp tên không bị chặn bởi mức này)
static const NSUInteger kCacheHardMax      = 6000;   // trần cứng của RAM Cache
static const NSUInteger kCacheTextLimit    = 3000;   // số ký tự tối đa lưu cho mỗi class trong Cache
static const NSUInteger kHistoryPairs      = 4;      // số lượt hỏi-đáp gần nhất gửi kèm làm ngữ cảnh
static const NSUInteger kMaxStoredItems    = 200;    // số mục tối đa trong Khu lưu trữ
static const NSUInteger kMaxSearchResults  = 80;     // số kết quả tối đa của Tra cứu Dump

#pragma mark - Tiện ích chuỗi

static NSString *CStr(const char *c) {
    if (!c) return @"";
    NSString *s = [NSString stringWithUTF8String:c];
    return s ? s : @"";
}

static NSString *Trim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark - IL2CPP bindings (nạp động bằng dlsym)

// --- Bắt buộc ---
static void*       (*il_domain_get)(void);
static void**      (*il_domain_get_assemblies)(void *, size_t *);
static void*       (*il_assembly_get_image)(void *);
static size_t      (*il_image_get_class_count)(void *);
static void*       (*il_image_get_class)(void *, size_t);
static const char* (*il_class_get_name)(void *);
static void*       (*il_class_get_fields)(void *, void **);
static void*       (*il_class_get_methods)(void *, void **);
static const char* (*il_field_get_name)(void *);
static size_t      (*il_field_get_offset)(void *);
static const char* (*il_method_get_name)(void *);
// --- Tùy chọn (thiếu thì bỏ bớt thông tin) ---
static const char* (*il_image_get_name)(void *);
static const char* (*il_class_get_namespace)(void *);
static int32_t     (*il_class_get_flags)(void *);
static void*       (*il_class_get_parent)(void *);
static void*       (*il_class_get_properties)(void *, void **);
static void*       (*il_class_get_field_from_name)(void *, const char *);
static void*       (*il_class_from_name)(void *, const char *, const char *);
static void*       (*il_class_from_type)(void *);
static bool        (*il_class_is_enum)(void *);
static bool        (*il_class_is_valuetype)(void *);
static void*       (*il_field_get_type)(void *);
static int32_t     (*il_field_get_flags)(void *);
static void        (*il_field_static_get_value)(void *, void *);
static uint32_t    (*il_method_get_flags)(void *, uint32_t *);
static int32_t     (*il_method_get_param_count)(void *);
static void*       (*il_method_get_param)(void *, uint32_t);
static const char* (*il_method_get_param_name)(void *, uint32_t);
static void*       (*il_method_get_return_type)(void *);
static const char* (*il_property_get_name)(void *);
static void*       (*il_property_get_get_method)(void *);
static void*       (*il_property_get_set_method)(void *);
static bool        (*il_type_is_byref)(void *);
static void        (*il_runtime_class_init)(void *);

static BOOL gIl2cppReady = NO;
static NSString *gIl2cppError = nil;

static void *Sym(void *h, const char *name) {
    void *p = (h && h != RTLD_DEFAULT) ? dlsym(h, name) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return p;
}

static BOOL LoadIl2cpp(void) {
    if (gIl2cppReady) return YES;

    NSString *fw = [[NSBundle mainBundle].privateFrameworksPath
                    stringByAppendingString:@"/UnityFramework.framework/UnityFramework"];
    void *h = dlopen(fw.UTF8String, RTLD_NOW | RTLD_NOLOAD);
    if (!h) h = dlopen(fw.UTF8String, RTLD_LAZY);
    if (!h) h = RTLD_DEFAULT;

#define AIMOL_SYM(n) il_##n = (decltype(il_##n))Sym(h, "il2cpp_" #n)
    AIMOL_SYM(domain_get);            AIMOL_SYM(domain_get_assemblies);
    AIMOL_SYM(assembly_get_image);    AIMOL_SYM(image_get_class_count);
    AIMOL_SYM(image_get_class);       AIMOL_SYM(class_get_name);
    AIMOL_SYM(class_get_fields);      AIMOL_SYM(class_get_methods);
    AIMOL_SYM(field_get_name);        AIMOL_SYM(field_get_offset);
    AIMOL_SYM(method_get_name);
    AIMOL_SYM(image_get_name);        AIMOL_SYM(class_get_namespace);
    AIMOL_SYM(class_get_flags);       AIMOL_SYM(class_get_parent);
    AIMOL_SYM(class_get_properties);  AIMOL_SYM(class_get_field_from_name);
    AIMOL_SYM(class_from_name);       AIMOL_SYM(class_from_type);
    AIMOL_SYM(class_is_enum);         AIMOL_SYM(class_is_valuetype);
    AIMOL_SYM(field_get_type);        AIMOL_SYM(field_get_flags);
    AIMOL_SYM(field_static_get_value);
    AIMOL_SYM(method_get_flags);      AIMOL_SYM(method_get_param_count);
    AIMOL_SYM(method_get_param);      AIMOL_SYM(method_get_param_name);
    AIMOL_SYM(method_get_return_type);
    AIMOL_SYM(property_get_name);     AIMOL_SYM(property_get_get_method);
    AIMOL_SYM(property_get_set_method);
    AIMOL_SYM(type_is_byref);
    AIMOL_SYM(runtime_class_init);
#undef AIMOL_SYM

    NSMutableString *missing = [NSMutableString string];
#define AIMOL_REQ(n) if (!il_##n) { [missing appendFormat:@"il2cpp_%s ", #n]; }
    AIMOL_REQ(domain_get); AIMOL_REQ(domain_get_assemblies); AIMOL_REQ(assembly_get_image);
    AIMOL_REQ(image_get_class_count); AIMOL_REQ(image_get_class); AIMOL_REQ(class_get_name);
    AIMOL_REQ(class_get_fields); AIMOL_REQ(class_get_methods); AIMOL_REQ(field_get_name);
    AIMOL_REQ(field_get_offset); AIMOL_REQ(method_get_name);
#undef AIMOL_REQ

    if (missing.length > 0) {
        gIl2cppError = [NSString stringWithFormat:@"Thiếu hàm bắt buộc: %@(game không phải Unity IL2CPP hoặc symbol bị strip).", missing];
        return NO;
    }
    gIl2cppReady = YES;
    return YES;
}

#pragma mark - Module / bộ nhớ

static NSString *gModuleName = nil;   // tên file chứa mã IL2CPP (xác định khi Dump)
static uintptr_t gDumpBase = 0;

static uintptr_t ModuleBase(NSString *name) {
    NSString *n = name;
    if (![n isKindOfClass:[NSString class]] || n.length == 0 || [[n lowercaseString] isEqualToString:@"auto"]) {
        NSString *gm = nil;
        @synchronized (kCacheLockToken) { gm = gModuleName; }
        n = gm.length ? gm : @"UnityFramework";
    }
    const char *want = n.UTF8String;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        const char *slash = strrchr(path, '/');
        const char *base = slash ? slash + 1 : path;
        if (strcmp(base, want) == 0) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

static intptr_t ModuleSlide(uintptr_t base) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if ((uintptr_t)_dyld_get_image_header(i) == base) return _dyld_get_image_vmaddr_slide(i);
    }
    return 0;
}

static BOOL MemRead(uintptr_t a, void *out, size_t n) {
    if (a < 0x10000 || n == 0) return NO;
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)a, (vm_size_t)n,
                                         (vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == n;
}

static BOOL MemWrite(uintptr_t a, const void *src, size_t n) {
    if (a < 0x10000 || n == 0) return NO;
    vm_protect(mach_task_self(), (vm_address_t)a, (vm_size_t)n, 0,
               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    kern_return_t kr = vm_write(mach_task_self(), (vm_address_t)a, (vm_offset_t)src,
                                (mach_msg_type_number_t)n);
    return kr == KERN_SUCCESS;
}

#ifdef AIMOL_HAS_DOBBY
// Hook qua Dobby (chỉ bật khi có dobby.h + libdobby lúc build)
extern "C" int AIMOLHook(void *target, void *replace, void **orig) {
    return DobbyHook(target, replace, orig);
}
#endif


#pragma mark - Nhật ký ghi trước (giúp biết lệnh nào làm game sập)

static NSString *gSessionID = nil;
static int gOpCounter = 0;
static FILE *gLogFP = NULL;
static void (^gUILogger)(NSString *) = nil;     // UI đăng ký để nhận tin từ kiểm tra trễ
static void (^gUINotifier)(NSString *) = nil;   // UI đăng ký để hiện thông báo cạnh nút nổi

static NSString *DocsDir(void) {
    NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return d ? d : NSTemporaryDirectory();
}

static NSString *LogPath(void) { return [DocsDir() stringByAppendingPathComponent:@"AIMOL_log.txt"]; }

static void UILog(NSString *s) {
    void (^b)(NSString *) = gUILogger;
    if (b && s) dispatch_async(dispatch_get_main_queue(), ^{ b(s); });
}

static void UINotify(NSString *s) {
    void (^b)(NSString *) = gUINotifier;
    if (b && s) dispatch_async(dispatch_get_main_queue(), ^{ b(s); });
}

// Ghi một dòng và đẩy xuống hệ thống ngay (fflush), nên vẫn còn nếu game sập ngay sau đó
static void AimolLog(NSString *line) {
    const char *c = line.UTF8String ? line.UTF8String : "";
    @synchronized (kCacheLockToken) {
        if (!gLogFP) gLogFP = fopen(LogPath().fileSystemRepresentation, "a");
        if (!gLogFP) return;
        time_t t = time(NULL);
        struct tm tmv;
        localtime_r(&t, &tmv);
        char ts[16];
        strftime(ts, sizeof(ts), "%H:%M:%S", &tmv);
        fprintf(gLogFP, "[%s] %s\n", ts, c);
        fflush(gLogFP);
    }
}

static NSString *GameVersionTag(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    id sv = info[@"CFBundleShortVersionString"];
    return [NSString stringWithFormat:@"v%@", [sv isKindOfClass:[NSString class]] ? (NSString *)sv : @"?"];
}

static NSString *GameBuildKey(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    id sv = info[@"CFBundleShortVersionString"];
    id bv = info[@"CFBundleVersion"];
    return [NSString stringWithFormat:@"%@-%@", [sv isKindOfClass:[NSString class]] ? sv : @"?",
            [bv isKindOfClass:[NSString class]] ? bv : @"?"];
}

// Cắt nhật ký nếu quá lớn (giữ phần cuối), rồi mở phiên mới
static void AimolLogInit(void) {
    NSString *path = LogPath();
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attr fileSize] > 262144) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        if (d.length > 100000) {
            NSData *tail = [d subdataWithRange:NSMakeRange(d.length - 100000, 100000)];
            const uint8_t *p = (const uint8_t *)tail.bytes;
            NSUInteger skip = 0;
            while (skip < tail.length && p[skip] != '\n') skip++;
            if (skip < tail.length) tail = [tail subdataWithRange:NSMakeRange(skip + 1, tail.length - skip - 1)];
            [tail writeToFile:path atomically:YES];
        }
    }
    gSessionID = [NSString stringWithFormat:@"%04x", (unsigned)arc4random_uniform(0x10000)];
    AimolLog([NSString stringWithFormat:@"=== Phiên mới %@ | game %@ ===", gSessionID, GameBuildKey()]);
}

static NSString *OpBegin(NSString *desc) {
    int n;
    @synchronized (kCacheLockToken) { n = ++gOpCounter; }
    NSString *tag = [NSString stringWithFormat:@"%@-%d", gSessionID ? gSessionID : @"x", n];
    AimolLog([NSString stringWithFormat:@"BEGIN#%@ %@", tag, desc]);
    return tag;
}

static void OpEnd(NSString *tag, NSString *result) {
    if (!tag) return;
    NSString *r = result ? result : @"";
    if (r.length > 160) r = [r substringToIndex:160];
    AimolLog([NSString stringWithFormat:@"END#%@ %@", tag, r]);
}

// Tìm lệnh còn dở ở phiên trước (BEGIN không có END). Gọi TRƯỚC AimolLogInit.
// Sau khi báo, ghi END để không báo lại ở lần sau.
static NSString *PreviousSessionIssue(void) {
    NSData *d = [NSData dataWithContentsOfFile:LogPath()];
    if (d.length == 0) return nil;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) return nil;
    NSMutableDictionary<NSString *, NSString *> *open = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSString *ln in [s componentsSeparatedByString:@"\n"]) {
        NSRange rb = [ln rangeOfString:@"BEGIN#"];
        NSRange re = [ln rangeOfString:@"END#"];
        BOOL isBegin = (rb.location != NSNotFound);
        if (!isBegin && re.location == NSNotFound) continue;
        NSRange r = isBegin ? rb : re;
        NSString *rest = [ln substringFromIndex:NSMaxRange(r)];
        NSRange sp = [rest rangeOfString:@" "];
        NSString *tag = (sp.location == NSNotFound) ? rest : [rest substringToIndex:sp.location];
        NSString *desc = (sp.location == NSNotFound) ? @"" : [rest substringFromIndex:sp.location + 1];
        if (isBegin) { open[tag] = desc; [order addObject:tag]; }
        else { [open removeObjectForKey:tag]; }
    }
    if (open.count == 0) return nil;
    NSString *issue = nil;
    for (NSString *tag in [order reverseObjectEnumerator]) {
        if (open[tag]) { issue = open[tag]; break; }
    }
    if (open.count > 0) {
        FILE *fp = fopen(LogPath().fileSystemRepresentation, "a");
        if (fp) {
            for (NSString *tag in open) fprintf(fp, "[--:--:--] END#%s (đã báo ở phiên sau)\n", tag.UTF8String);
            fclose(fp);
        }
    }
    return issue;
}

static NSString *AimolLogTail(NSUInteger lines) {
    NSData *d = [NSData dataWithContentsOfFile:LogPath()];
    if (d.length == 0) return @"(nhật ký trống)";
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) return @"(không đọc được nhật ký)";
    NSArray<NSString *> *all = [s componentsSeparatedByString:@"\n"];
    NSUInteger n = all.count;
    NSUInteger from = n > lines + 1 ? n - lines - 1 : 0;
    return [[all subarrayWithRange:NSMakeRange(from, n - from)] componentsJoinedByString:@"\n"];
}

#pragma mark - Đánh dấu tiến độ Dump (để lần sau bỏ qua class gây sập)

typedef struct { uint32_t magic; uint32_t state; uint32_t asmIdx; uint32_t clsIdx; } DumpMark;
static const uint32_t kDumpMagic = 0x41494D4Cu;
static int gMarkFD = -1;

static NSString *MarkPath(void) { return [DocsDir() stringByAppendingPathComponent:@"AIMOL_dumpmark.bin"]; }

// Ghi đè một bản ghi cố định 16 byte (không phình file); mỗi class một lần pwrite
static void DumpMarkWrite(uint32_t state, uint32_t a, uint32_t c) {
    if (gMarkFD < 0) gMarkFD = open(MarkPath().fileSystemRepresentation, O_RDWR | O_CREAT, 0644);
    if (gMarkFD < 0) return;
    DumpMark m;
    m.magic = kDumpMagic; m.state = state; m.asmIdx = a; m.clsIdx = c;
    pwrite(gMarkFD, &m, sizeof(m), 0);
}

static NSSet<NSString *> *DumpSkipSet(void) {
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSkipKey];
    id arr = all[GameBuildKey()];
    if (![arr isKindOfClass:[NSArray class]]) return [NSSet set];
    return [NSSet setWithArray:(NSArray *)arr];
}

static void DumpSkipAdd(uint32_t a, uint32_t c) {
    NSMutableDictionary *all = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kSkipKey] mutableCopy];
    if (!all) all = [NSMutableDictionary dictionary];
    NSString *k = GameBuildKey();
    NSMutableArray *arr = [NSMutableArray array];
    id existing = all[k];
    if ([existing isKindOfClass:[NSArray class]]) [arr addObjectsFromArray:(NSArray *)existing];
    NSString *item = [NSString stringWithFormat:@"%u:%u", a, c];
    if (![arr containsObject:item]) [arr addObject:item];
    while (arr.count > 50) [arr removeObjectAtIndex:0];
    all[k] = arr;
    [[NSUserDefaults standardUserDefaults] setObject:all forKey:kSkipKey];
}

// Gọi một lần lúc khởi động: nếu lần Dump trước dừng giữa chừng thì ghi nhớ class đang xử lý để bỏ qua
static NSString *DumpCheckPrevious(void) {
    int fd = open(MarkPath().fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return nil;
    DumpMark m;
    ssize_t n = pread(fd, &m, sizeof(m), 0);
    close(fd);
    if (n != (ssize_t)sizeof(m) || m.magic != kDumpMagic || m.state != 1) return nil;
    DumpSkipAdd(m.asmIdx, m.clsIdx);
    DumpMarkWrite(0, 0, 0);
    return [NSString stringWithFormat:@"Lần Dump trước dừng giữa chừng (game sập hoặc bị thoát) ở class #%u của assembly #%u. Lần Dump sau sẽ bỏ qua class này.", m.clsIdx, m.asmIdx];
}

#pragma mark - Dump metadata (CHỈ chạy khi người dùng bấm nút)

static NSMutableArray<NSDictionary *> *gCache = nil;   // RAM Cache: class chứa từ khóa quan trọng
static NSString *gDumpPath = nil;
static BOOL gLastDumpOK = NO;

static NSArray<NSString *> *DumpKeywords(void) {
    return @[@"Car", @"Vehicle", @"Physics", @"Wheel", @"Engine", @"Suspension", @"Speed",
             @"Torque", @"Power", @"Rpm", @"Brake", @"Gear", @"Color", @"Paint", @"Rigidbody"];
}

// Khớp từ khóa. Từ khóa ngắn ("car") yêu cầu ranh giới từ để tránh Card, Scar, Carpet...
static BOOL HasKeyword(NSString *s, NSString *kw) {
    NSUInteger len = s.length;
    if (len == 0) return NO;
    NSRange search = NSMakeRange(0, len);
    while (search.length > 0) {
        NSRange r = [s rangeOfString:kw options:NSCaseInsensitiveSearch range:search];
        if (r.location == NSNotFound) return NO;
        if (kw.length > 3) return YES;
        BOOL startOK = YES;
        if (r.location > 0) {
            unichar prev = [s characterAtIndex:r.location - 1];
            unichar first = [s characterAtIndex:r.location];
            BOOL prevIsLetter = [[NSCharacterSet letterCharacterSet] characterIsMember:prev];
            BOOL firstIsUpper = [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:first];
            startOK = (!prevIsLetter) || firstIsUpper;
        }
        BOOL endOK = YES;
        NSUInteger e = NSMaxRange(r);
        if (e < len) {
            unichar next = [s characterAtIndex:e];
            endOK = ![[NSCharacterSet lowercaseLetterCharacterSet] characterIsMember:next];
        }
        if (startOK && endOK) return YES;
        search = NSMakeRange(e, len - e);
    }
    return NO;
}

static NSString *TypeName(void *type) {
    if (!type || !il_class_from_type || !il_class_get_name) return @"?";
    void *k = il_class_from_type(type);
    if (!k) return @"?";
    NSString *n = CStr(il_class_get_name(k));
    return n.length ? n : @"?";
}

static NSString *AccessStr(int32_t f) {   // dùng chung cho field và method
    switch (f & 7) {
        case 1: return @"private ";
        case 2: case 3: return @"internal ";
        case 4: return @"protected ";
        case 5: return @"protected internal ";
        case 6: return @"public ";
        default: return @"";
    }
}

static NSString *TypeVisStr(int32_t f) {
    switch (f & 7) {
        case 1: case 2: return @"public ";
        case 4: return @"protected ";
        case 3: return @"private ";
        case 7: return @"protected internal ";
        default: return @"internal ";
    }
}

// Dump một class thành văn bản kiểu C#. Trả NO nếu class không hợp lệ.
static BOOL ProcessClass(void *k, NSString **outText, NSString **outFullName, NSString **outFieldNames) {
    const char *rawName = il_class_get_name(k);
    if (!rawName) return NO;
    NSString *cname = CStr(rawName);
    NSString *cns = il_class_get_namespace ? CStr(il_class_get_namespace(k)) : @"";
    int32_t cf = il_class_get_flags ? il_class_get_flags(k) : 0;
    bool isEnum = il_class_is_enum ? il_class_is_enum(k) : false;
    bool isVT = il_class_is_valuetype ? il_class_is_valuetype(k) : false;

    NSMutableString *b = [NSMutableString string];
    [b appendFormat:@"// Namespace: %@\n", cns];
    [b appendString:TypeVisStr(cf)];
    if ((cf & 0x80) && (cf & 0x100)) [b appendString:@"static "];
    else if (!(cf & 0x20) && (cf & 0x80)) [b appendString:@"abstract "];
    else if (!isVT && !isEnum && (cf & 0x100)) [b appendString:@"sealed "];
    if (cf & 0x20) [b appendString:@"interface "];
    else if (isEnum) [b appendString:@"enum "];
    else if (isVT) [b appendString:@"struct "];
    else [b appendString:@"class "];
    [b appendString:cname];
    if (il_class_get_parent && !isEnum) {
        void *parent = il_class_get_parent(k);
        if (parent && il_class_get_name) {
            NSString *pn = CStr(il_class_get_name(parent));
            if (pn.length && ![pn isEqualToString:@"Object"]) [b appendFormat:@" : %@", pn];
        }
    }
    [b appendString:@"\n{\n"];

    // --- Fields ---
    NSMutableString *fields = [NSMutableString string];
    NSMutableString *fieldNames = [NSMutableString string];
    void *it = NULL;
    void *fld = NULL;
    while ((fld = il_class_get_fields(k, &it)) != NULL) {
        int32_t ff = il_field_get_flags ? il_field_get_flags(fld) : 0;
        NSString *fname = CStr(il_field_get_name(fld));
        NSString *ftype = (il_field_get_type != NULL) ? TypeName(il_field_get_type(fld)) : @"?";
        BOOL isConst = (ff & 0x40) != 0;
        [fields appendString:@"\t"];
        [fields appendString:AccessStr(ff)];
        if (isConst) {
            [fields appendString:@"const "];
        } else {
            if (ff & 0x10) [fields appendString:@"static "];
            if (ff & 0x20) [fields appendString:@"readonly "];
        }
        [fields appendFormat:@"%@ %@", ftype, fname];
        if (isConst) [fields appendString:@";\n"];
        else [fields appendFormat:@"; // 0x%zX\n", il_field_get_offset(fld)];
        [fieldNames appendFormat:@"%@ ", fname];
    }
    if (fields.length > 0) [b appendFormat:@"\t// Fields\n%@", fields];

    // --- Properties ---
    if (il_class_get_properties && il_property_get_name) {
        NSMutableString *props = [NSMutableString string];
        it = NULL;
        void *prop = NULL;
        while ((prop = il_class_get_properties(k, &it)) != NULL) {
            NSString *pn = CStr(il_property_get_name(prop));
            void *g = il_property_get_get_method ? il_property_get_get_method(prop) : NULL;
            void *s = il_property_get_set_method ? il_property_get_set_method(prop) : NULL;
            NSString *pt = @"?";
            if (g && il_method_get_return_type) pt = TypeName(il_method_get_return_type(g));
            else if (s && il_method_get_param) pt = TypeName(il_method_get_param(s, 0));
            [props appendFormat:@"\t%@ %@ { %@%@}\n", pt, pn, g ? @"get; " : @"", s ? @"set; " : @""];
        }
        if (props.length > 0) [b appendFormat:@"\n\t// Properties\n%@", props];
    }

    // --- Methods ---
    NSMutableString *methods = [NSMutableString string];
    it = NULL;
    void *m = NULL;
    while ((m = il_class_get_methods(k, &it)) != NULL) {
        uint32_t iflags = 0;
        uint32_t mf = il_method_get_flags ? il_method_get_flags(m, &iflags) : 0;
        void *mp = *(void **)m;   // MethodInfo->methodPointer nằm ở offset 0
        NSString *tail = nil;
        if (!mp || (mf & 0x400)) {
            tail = @"// RVA: -1";
        } else {
            uintptr_t p = (uintptr_t)mp;
            if (gDumpBase && p >= gDumpBase && (p - gDumpBase) < 0x20000000) {
                tail = [NSString stringWithFormat:@"// RVA: 0x%lX Ptr: %p", (unsigned long)(p - gDumpBase), mp];
            } else {
                Dl_info di;
                memset(&di, 0, sizeof(di));
                if (dladdr(mp, &di) && di.dli_fbase) {
                    if (!gDumpBase) {
                        gDumpBase = (uintptr_t)di.dli_fbase;
                        const char *slash = di.dli_fname ? strrchr(di.dli_fname, '/') : NULL;
                        NSString *mn = CStr(slash ? slash + 1 : di.dli_fname);
                        @synchronized (kCacheLockToken) { gModuleName = mn; }
                    }
                    tail = [NSString stringWithFormat:@"// RVA: 0x%lX Ptr: %p",
                            (unsigned long)(p - (uintptr_t)di.dli_fbase), mp];
                } else {
                    tail = [NSString stringWithFormat:@"// Ptr: %p", mp];
                }
            }
        }
        NSString *ret = (il_method_get_return_type != NULL) ? TypeName(il_method_get_return_type(m)) : @"?";
        int32_t pc = il_method_get_param_count ? il_method_get_param_count(m) : 0;
        NSMutableString *ps = [NSMutableString string];
        for (int32_t i = 0; i < pc; i++) {
            void *pt = il_method_get_param ? il_method_get_param(m, (uint32_t)i) : NULL;
            NSString *ptn = pt ? TypeName(pt) : @"?";
            NSString *pnm = il_method_get_param_name ? CStr(il_method_get_param_name(m, (uint32_t)i)) : @"";
            if (pnm.length == 0) pnm = [NSString stringWithFormat:@"a%d", (int)i];
            if (i > 0) [ps appendString:@", "];
            if (pt && il_type_is_byref && il_type_is_byref(pt)) [ps appendString:@"ref "];
            [ps appendFormat:@"%@ %@", ptn, pnm];
        }
        [methods appendString:@"\t"];
        [methods appendString:AccessStr((int32_t)mf)];
        if (mf & 0x10) [methods appendString:@"static "];
        if (mf & 0x400) [methods appendString:@"abstract "];
        else if (mf & 0x40) [methods appendString:@"virtual "];
        [methods appendFormat:@"%@ %@(%@); %@\n", ret, CStr(il_method_get_name(m)), ps, tail];
    }
    if (methods.length > 0) [b appendFormat:@"\n\t// Methods\n%@", methods];
    [b appendString:@"}\n\n"];

    *outText = b;
    *outFullName = cns.length ? [NSString stringWithFormat:@"%@.%@", cns, cname] : cname;
    *outFieldNames = fieldNames;
    return YES;
}


static NSString *AIMOLDump(void (^progress)(double)) {
    gLastDumpOK = NO;
    if (!LoadIl2cpp()) return [NSString stringWithFormat:@"❌ Không nạp được IL2CPP. %@", gIl2cppError ? gIl2cppError : @""];
    void *dom = il_domain_get();
    if (!dom) return @"❌ il2cpp_domain_get trả về NULL: game chưa khởi tạo IL2CPP xong. Vào màn hình chính/trận rồi bấm lại.";
    size_t asmCount = 0;
    void **asms = il_domain_get_assemblies(dom, &asmCount);
    if (!asms || asmCount == 0) return @"❌ Chưa có assembly nào được nạp. Đợi game tải xong rồi bấm lại.";

    NSString *path = [DocsDir() stringByAppendingPathComponent:@"AIMOL_dump.cs"];
    FILE *fp = fopen(path.fileSystemRepresentation, "w");
    if (!fp) return [NSString stringWithFormat:@"❌ Không tạo được file dump: %@", path];

    @synchronized (kCacheLockToken) { gModuleName = nil; }
    gDumpBase = 0;

    size_t total = 0;
    for (size_t i = 0; i < asmCount; i++) {
        void *img = il_assembly_get_image(asms[i]);
        if (img) total += il_image_get_class_count(img);
    }
    if (total == 0) total = 1;

    NSSet<NSString *> *skip = DumpSkipSet();
    NSString *opTag = OpBegin(@"DUMP");
    DumpMarkWrite(1, 0, 0);

    NSMutableArray<NSDictionary *> *cache = [NSMutableArray array];
    NSArray<NSString *> *keywords = DumpKeywords();
    size_t done = 0, classCount = 0, skipped = 0;

    fputs("// AIMOL IL2CPP dump (chạy thủ công bằng nút DUMP METADATA)\n", fp);
    fputs("// Field: '// 0xNN' là offset TRONG đối tượng (không phải địa chỉ từ đầu module).\n", fp);
    fputs("// Method: RVA tính từ đầu module (module header); Ptr là con trỏ lúc chạy.\n\n", fp);

    for (size_t i = 0; i < asmCount; i++) {
        void *img = il_assembly_get_image(asms[i]);
        if (!img) continue;
        if (il_image_get_name) {
            NSString *line = [NSString stringWithFormat:@"// ===== Image %zu: %@ =====\n", i, CStr(il_image_get_name(img))];
            fputs(line.UTF8String, fp);
        }
        size_t cc = il_image_get_class_count(img);
        for (size_t j = 0; j < cc; j++) {
            @autoreleasepool {
                done++;
                if (skip.count > 0 && [skip containsObject:[NSString stringWithFormat:@"%u:%u", (unsigned)i, (unsigned)j]]) {
                    skipped++;
                    continue;
                }
                DumpMarkWrite(1, (uint32_t)i, (uint32_t)j);   // nếu sập ngay sau dòng này, lần sau sẽ bỏ qua class này
                void *k = il_image_get_class(img, j);
                if (k) {
                    NSString *text = nil, *fullName = nil, *fieldNames = nil;
                    if (ProcessClass(k, &text, &fullName, &fieldNames)) {
                        classCount++;
                        fputs(text.UTF8String, fp);
                        NSInteger score = 0;
                        for (NSString *kw in keywords) {
                            if (HasKeyword(fullName, kw)) { score = 5; break; }
                        }
                        if (score == 0) {
                            for (NSString *kw in keywords) {
                                if (HasKeyword(fieldNames, kw)) { score = 2; break; }
                            }
                        }
                        BOOL room = cache.count < kCacheMaxClasses || (score == 5 && cache.count < kCacheHardMax);
                        if (score > 0 && room) {
                            NSString *stored = text.length > kCacheTextLimit ? [text substringToIndex:kCacheTextLimit] : text;
                            [cache addObject:@{@"name": fullName,
                                               @"lname": [fullName lowercaseString],
                                               @"score": @(score),
                                               @"text": stored}];
                        }
                    }
                }
                if (progress && (done % 500 == 0)) progress((double)done / (double)total);
            }
        }
    }

    NSString *mod = nil;
    @synchronized (kCacheLockToken) { mod = gModuleName; }
    uintptr_t base = gDumpBase ? gDumpBase : ModuleBase(mod);
    NSString *footer = [NSString stringWithFormat:@"// Module: %@  RuntimeBase: 0x%lX  Slide: 0x%lX\n",
                        mod.length ? mod : @"?", (unsigned long)base, (unsigned long)ModuleSlide(base)];
    fputs(footer.UTF8String, fp);
    fclose(fp);

    DumpMarkWrite(0, 0, 0);
    OpEnd(opTag, [NSString stringWithFormat:@"ok %zu class", classCount]);

    @synchronized (kCacheLockToken) {
        gCache = cache;
        gDumpPath = path;
    }
    gLastDumpOK = YES;
    NSString *skipNote = skipped > 0 ? [NSString stringWithFormat:@"\nĐã bỏ qua %zu class từng làm game sập.", skipped] : @"";
    return [NSString stringWithFormat:@"✅ Dump Completed: %zu assembly, %zu class, %lu class khớp từ khóa (đã lưu RAM Cache).%@\nModule: %@\nFile đầy đủ: %@\n(Bấm nút chia sẻ ở thanh trên để lưu file ra ứng dụng Tệp.)",
            asmCount, classCount, (unsigned long)cache.count, skipNote, mod.length ? mod : @"?", path];
}

// Lấy các class liên quan nhất tới câu hỏi để gửi kèm cho AI (giới hạn theo kDumpContextBudget)
static NSString *BuildDumpContext(NSString *question) {
    NSArray<NSDictionary *> *entries = nil;
    @synchronized (kCacheLockToken) { entries = [gCache copy]; }
    if (entries.count == 0) return @"";

    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSCharacterSet *sep = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    for (NSString *w in [[question lowercaseString] componentsSeparatedByCharactersInSet:sep]) {
        if (w.length >= 4 && tokens.count < 12) [tokens addObject:w];
    }
    NSMutableArray<NSDictionary *> *scored = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSDictionary *e in entries) {
        NSInteger s = [e[@"score"] integerValue] * 10;
        NSString *ln = e[@"lname"];
        for (NSString *t in tokens) {
            if ([ln containsString:t]) s += 25;
        }
        [scored addObject:@{@"s": @(s), @"e": e}];
    }
    [scored sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger x = [[(NSDictionary *)a objectForKey:@"s"] integerValue];
        NSInteger y = [[(NSDictionary *)b objectForKey:@"s"] integerValue];
        if (x > y) return NSOrderedAscending;
        if (x < y) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableString *out = [NSMutableString stringWithFormat:
        @"\n\n[DUMP CACHE - %lu class khớp từ khóa; hiển thị các class liên quan nhất]\n", (unsigned long)entries.count];
    NSUInteger used = 0;
    for (NSDictionary *item in scored) {
        NSDictionary *e = item[@"e"];
        NSString *t = e[@"text"];
        if (used + t.length > kDumpContextBudget) continue;
        [out appendString:t];
        used += t.length;
        if (used > (NSUInteger)(kDumpContextBudget * 0.98)) break;
    }
    return out;
}

#pragma mark - Công cụ patch bộ nhớ

static BOOL ParseHexStrict(NSString *s, uintptr_t *out) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSString *t = Trim(s);
    if ([t hasPrefix:@"0x"] || [t hasPrefix:@"0X"]) t = [t substringFromIndex:2];
    if (t.length == 0 || t.length > 16) return NO;
    char *end = NULL;
    unsigned long long v = strtoull(t.UTF8String, &end, 16);
    if (!end || *end != '\0') return NO;
    *out = (uintptr_t)v;
    return YES;
}

static BOOL GetHex(NSDictionary *d, NSString *key, uintptr_t *out) {
    id v = d[key];
    if (![v isKindOfClass:[NSString class]]) return NO;
    return ParseHexStrict((NSString *)v, out);
}

static BOOL ParseNumber(id v, double *out) {
    if ([v isKindOfClass:[NSNumber class]]) { *out = [(NSNumber *)v doubleValue]; return YES; }
    if ([v isKindOfClass:[NSString class]]) {
        NSString *t = Trim((NSString *)v);
        if (t.length == 0) return NO;
        char *end = NULL;
        double x = strtod(t.UTF8String, &end);
        if (!end || *end != '\0') return NO;
        *out = x;
        return YES;
    }
    return NO;
}

static BOOL ParseBool(id v, BOOL *out) {
    if ([v isKindOfClass:[NSNumber class]]) { *out = [(NSNumber *)v boolValue]; return YES; }
    if ([v isKindOfClass:[NSString class]]) {
        NSString *t = [Trim((NSString *)v) lowercaseString];
        if ([t isEqualToString:@"true"] || [t isEqualToString:@"1"] || [t isEqualToString:@"on"]) { *out = YES; return YES; }
        if ([t isEqualToString:@"false"] || [t isEqualToString:@"0"] || [t isEqualToString:@"off"]) { *out = NO; return YES; }
    }
    return NO;
}

static NSUInteger VecCount(NSString *t) {
    if ([t isEqualToString:@"float2"]) return 2;
    if ([t isEqualToString:@"float3"]) return 3;
    if ([t isEqualToString:@"float4"]) return 4;
    return 0;
}

static size_t TypeSize(NSString *t) {
    if ([t isEqualToString:@"float"] || [t isEqualToString:@"int"]) return 4;
    if ([t isEqualToString:@"double"] || [t isEqualToString:@"long"]) return 8;
    if ([t isEqualToString:@"bool"]) return 1;
    return VecCount(t) * 4;   // float2/3/4 => 8/12/16, kiểu lạ => 0
}

static NSString *HexOf(const uint8_t *b, size_t n) {
    NSMutableString *h = [NSMutableString string];
    for (size_t i = 0; i < n; i++) [h appendFormat:@"%02X", b[i]];
    return h;
}

static NSString *FormatValue(const uint8_t *b, size_t n, NSString *type) {
    if ([type isEqualToString:@"float"] && n == 4) { float v; memcpy(&v, b, 4); return [NSString stringWithFormat:@"%g", (double)v]; }
    if ([type isEqualToString:@"double"] && n == 8) { double v; memcpy(&v, b, 8); return [NSString stringWithFormat:@"%g", v]; }
    if ([type isEqualToString:@"int"] && n == 4) { int32_t v; memcpy(&v, b, 4); return [NSString stringWithFormat:@"%d", (int)v]; }
    if ([type isEqualToString:@"long"] && n == 8) { int64_t v; memcpy(&v, b, 8); return [NSString stringWithFormat:@"%lld", (long long)v]; }
    if ([type isEqualToString:@"bool"] && n == 1) return b[0] ? @"true" : @"false";
    NSUInteger vc = VecCount(type);
    if (vc > 0 && n == vc * 4) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSUInteger i = 0; i < vc; i++) { float v; memcpy(&v, b + i * 4, 4); [parts addObject:[NSString stringWithFormat:@"%g", (double)v]]; }
        return [NSString stringWithFormat:@"(%@)", [parts componentsJoinedByString:@", "]];
    }
    return HexOf(b, n);
}

// Đọc 8 byte và hiển thị theo mọi kiểu cùng lúc (multiTypeRead)
static NSString *FormatAll(const uint8_t *b) {
    float f; int32_t i; double d; int64_t l;
    memcpy(&f, b, 4); memcpy(&i, b, 4); memcpy(&d, b, 8); memcpy(&l, b, 8);
    return [NSString stringWithFormat:@"float=%g | int=%d | double=%g | long=%lld | hex=%@",
            (double)f, (int)i, d, (long long)l, HexOf(b, 8)];
}

// Dựng chuỗi byte từ giá trị JSON theo kiểu. Trả NO và đặt *err nếu không hợp lệ.
static BOOL BuildValueBytes(NSString *type, id value, uint8_t *buf, size_t *n, NSString **err) {
    if (value == nil) { *err = @"Thiếu giá trị."; return NO; }
    if ([type isEqualToString:@"bytes"]) {
        if (![value isKindOfClass:[NSString class]]) { *err = @"Kiểu bytes cần giá trị là chuỗi hex, ví dụ \"00 00 80 3F\"."; return NO; }
        NSString *hex = [[[(NSString *)value stringByReplacingOccurrencesOfString:@" " withString:@""]
                          stringByReplacingOccurrencesOfString:@"0x" withString:@""] stringByReplacingOccurrencesOfString:@"0X" withString:@""];
        if (hex.length == 0 || (hex.length % 2) != 0 || hex.length > 128) { *err = @"Chuỗi hex phải có độ dài chẵn, tối đa 64 byte."; return NO; }
        for (NSUInteger i = 0; i < hex.length; i += 2) {
            NSString *pair = [hex substringWithRange:NSMakeRange(i, 2)];
            char *end = NULL;
            unsigned long v = strtoul(pair.UTF8String, &end, 16);
            if (!end || *end != '\0') { *err = @"Chuỗi hex chứa ký tự không hợp lệ."; return NO; }
            buf[i / 2] = (uint8_t)v;
        }
        *n = hex.length / 2;
        return YES;
    }
    NSUInteger vc = VecCount(type);
    if (vc > 0) {
        if (![value isKindOfClass:[NSArray class]] || [(NSArray *)value count] != vc) {
            *err = [NSString stringWithFormat:@"Kiểu %@ cần mảng %lu số, ví dụ [0.2, 0.5, 0.9].", type, (unsigned long)vc];
            return NO;
        }
        for (NSUInteger i = 0; i < vc; i++) {
            double x = 0;
            if (!ParseNumber([(NSArray *)value objectAtIndex:i], &x) || !std::isfinite(x)) { *err = @"Phần tử của mảng phải là số hợp lệ."; return NO; }
            float f = (float)x;
            if (!std::isfinite(f)) { *err = @"Giá trị float vượt phạm vi."; return NO; }
            memcpy(buf + i * 4, &f, 4);
        }
        *n = vc * 4;
        return YES;
    }
    if ([type isEqualToString:@"bool"]) {
        BOOL bv = NO;
        if (!ParseBool(value, &bv)) { *err = @"Giá trị kiểu bool phải là true/false."; return NO; }
        buf[0] = bv ? 1 : 0;
        *n = 1;
        return YES;
    }
    double num = 0;
    if (!ParseNumber(value, &num) || !std::isfinite(num)) { *err = @"Giá trị phải là số hợp lệ."; return NO; }
    if ([type isEqualToString:@"float"]) {
        float f = (float)num;
        if (!std::isfinite(f)) { *err = @"Giá trị float vượt phạm vi."; return NO; }
        memcpy(buf, &f, 4); *n = 4; return YES;
    }
    if ([type isEqualToString:@"double"]) { memcpy(buf, &num, 8); *n = 8; return YES; }
    if ([type isEqualToString:@"int"]) {
        if (num < -2147483648.0 || num > 2147483647.0) { *err = @"Giá trị int vượt phạm vi 32 bit."; return NO; }
        int32_t iv = (int32_t)std::llround(num);
        memcpy(buf, &iv, 4); *n = 4; return YES;
    }
    if ([type isEqualToString:@"long"]) {
        if (num < -9.2e18 || num > 9.2e18) { *err = @"Giá trị long vượt phạm vi."; return NO; }
        int64_t lv = (int64_t)std::llround(num);
        memcpy(buf, &lv, 8); *n = 8; return YES;
    }
    *err = [NSString stringWithFormat:@"Kiểu '%@' không hỗ trợ (dùng float, float2, float3, float4, double, int, long, bool, bytes).", type];
    return NO;
}

// So sánh có sai số cho kiểu float; các kiểu khác so sánh từng byte
static BOOL ValuesMatch(NSString *type, const uint8_t *a, const uint8_t *b, size_t n, double tol) {
    BOOL isF = [type isEqualToString:@"float"] || VecCount(type) > 0;
    if (isF && n % 4 == 0) {
        for (size_t i = 0; i < n; i += 4) {
            float x, y;
            memcpy(&x, a + i, 4); memcpy(&y, b + i, 4);
            double ref = std::max(1.0, std::fabs((double)y));
            if (!(std::fabs((double)x - (double)y) <= tol * ref)) return NO;
        }
        return YES;
    }
    if ([type isEqualToString:@"double"] && n == 8) {
        double x, y; memcpy(&x, a, 8); memcpy(&y, b, 8);
        return std::fabs(x - y) <= tol * std::max(1.0, std::fabs(y));
    }
    return memcmp(a, b, n) == 0;
}

// Tìm class theo tên đầy đủ "Namespace.Class" trong mọi assembly
static BOOL ValidName(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0 || s.length > 200) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < 0x20 || c == 0x7F) return NO;
    }
    return YES;
}

static void *FindClass(NSString *full) {
    if (!ValidName(full) || !LoadIl2cpp() || !il_class_from_name) return NULL;
    NSString *ns = @"";
    NSString *nm = full;
    NSRange r = [full rangeOfString:@"." options:NSBackwardsSearch];
    if (r.location != NSNotFound) {
        ns = [full substringToIndex:r.location];
        nm = [full substringFromIndex:r.location + 1];
    }
    void *dom = il_domain_get();
    if (!dom) return NULL;
    size_t n = 0;
    void **asms = il_domain_get_assemblies(dom, &n);
    if (!asms) return NULL;
    for (size_t i = 0; i < n; i++) {
        void *img = il_assembly_get_image(asms[i]);
        if (!img) continue;
        void *k = il_class_from_name(img, ns.UTF8String, nm.UTF8String);
        if (k) return k;
    }
    return NULL;
}

// Xác định địa chỉ cần đọc/ghi. Trả về chuỗi lỗi (hoặc nil nếu thành công).
// 'trace' ghi lại từng bước của chuỗi pointer để dễ gỡ lỗi.
static NSString *ResolveAddress(NSDictionary *d, uintptr_t *outAddr, NSString **outDesc, NSMutableString *trace) {
    id clsv = d[@"class"];
    NSArray *chain = [d[@"pointers"] isKindOfClass:[NSArray class]] ? (NSArray *)d[@"pointers"] : @[];

    if ([clsv isKindOfClass:[NSString class]] && [(NSString *)clsv length] > 0) {
        // ===== Chế độ theo đối tượng: static field (singleton) -> chuỗi pointer -> field =====
        NSString *cls = (NSString *)clsv;
        if (!LoadIl2cpp()) return gIl2cppError ? gIl2cppError : @"Không nạp được IL2CPP.";
        if (!il_class_from_name || !il_class_get_field_from_name || !il_field_static_get_value ||
            !il_field_get_flags || !il_field_get_offset) {
            return @"Game thiếu API IL2CPP cần cho patch theo đối tượng. Dùng chế độ theo module (module + offset) làm phương án phụ.";
        }
        void *klass = FindClass(cls);
        if (!klass) return [NSString stringWithFormat:@"Không tìm thấy class '%@' (kiểm tra lại tên trong Dump).", cls];

        id sfv = d[@"static_field"];
        if (![sfv isKindOfClass:[NSString class]] || !ValidName((NSString *)sfv)) {
            return @"Patch theo class cần 'static_field' (field static chứa đối tượng, ví dụ Instance).";
        }
        NSString *sfName = (NSString *)sfv;
        void *sf = il_class_get_field_from_name(klass, sfName.UTF8String);
        if (!sf) return [NSString stringWithFormat:@"Không có field '%@' trong class '%@'.", sfName, cls];
        if (!(il_field_get_flags(sf) & 0x10)) return [NSString stringWithFormat:@"Field '%@' không phải static.", sfName];

        if (il_runtime_class_init) il_runtime_class_init(klass);   // bảo đảm vùng static đã được khởi tạo (không làm gì nếu đã khởi tạo)
        uint64_t buf[8];
        memset(buf, 0, sizeof(buf));      // vùng đệm dư để field kiểu struct không làm tràn bộ nhớ
        il_field_static_get_value(sf, buf);
        uintptr_t addr = (uintptr_t)buf[0];
        [trace appendFormat:@"• static %@.%@ = 0x%lX\n", cls, sfName, (unsigned long)addr];
        if (addr < 0x10000) return [NSString stringWithFormat:@"Field static '%@' đang null: đối tượng chưa được tạo. Vào trận/chọn xe rồi thử lại.", sfName];

        for (id p in chain) {
            uintptr_t po = 0;
            if (![p isKindOfClass:[NSString class]] || !ParseHexStrict((NSString *)p, &po)) return @"'pointers' phải là mảng chuỗi hex, ví dụ [\"0x28\"].";
            uintptr_t next = 0;
            if (!MemRead(addr + po, &next, sizeof(next)) || next < 0x10000) {
                [trace appendFormat:@"• +0x%lX → không đọc được\n", (unsigned long)po];
                return @"Chuỗi pointer lỗi: không đọc được đối tượng con.";
            }
            [trace appendFormat:@"• +0x%lX → 0x%lX\n", (unsigned long)po, (unsigned long)next];
            addr = next;
        }

        NSString *fieldLabel = nil;
        id fv = d[@"field"];
        if ([fv isKindOfClass:[NSString class]] && [(NSString *)fv length] > 0) {
            void *fk = klass;
            id fcv = d[@"field_class"];
            if ([fcv isKindOfClass:[NSString class]] && [(NSString *)fcv length] > 0) {
                fk = FindClass((NSString *)fcv);
                if (!fk) return [NSString stringWithFormat:@"Không tìm thấy field_class '%@'.", fcv];
            }
            NSString *fname = (NSString *)fv;
            if (!ValidName(fname)) return @"Tên field không hợp lệ.";
            void *ff = il_class_get_field_from_name(fk, fname.UTF8String);
            if (!ff) return [NSString stringWithFormat:@"Không có field '%@' (kiểm tra tên trong Dump).", fname];
            if (il_field_get_flags(ff) & 0x10) return [NSString stringWithFormat:@"Field '%@' là static; hãy dùng static_field.", fname];
            size_t fo = il_field_get_offset(ff);
            addr += fo;
            [trace appendFormat:@"• field %@ +0x%lX → 0x%lX\n", fname, (unsigned long)fo, (unsigned long)addr];
            fieldLabel = fname;
        } else {
            uintptr_t off = 0;
            if (!GetHex(d, @"offset", &off)) return @"Thiếu 'field' (tên) hoặc 'offset' (chuỗi hex) để chọn trường cần ghi.";
            addr += off;
            [trace appendFormat:@"• offset +0x%lX → 0x%lX\n", (unsigned long)off, (unsigned long)addr];
            fieldLabel = [NSString stringWithFormat:@"+0x%lX", (unsigned long)off];
        }
        *outAddr = addr;
        *outDesc = [NSString stringWithFormat:@"%@.%@", cls, fieldLabel];
        return nil;
    }

    // ===== Chế độ theo module: địa chỉ = đầu module + offset =====
    uintptr_t off = 0;
    if (!GetHex(d, @"offset", &off) || off == 0) return @"'offset' phải là chuỗi hex hợp lệ (ví dụ \"0x1A8\") và khác 0.";
    id modv = d[@"module"];
    NSString *mod = [modv isKindOfClass:[NSString class]] ? (NSString *)modv : @"";
    uintptr_t base = ModuleBase(mod);
    if (base == 0) return [NSString stringWithFormat:@"Không tìm thấy module '%@'. Hãy bấm DUMP METADATA trước hoặc chỉ định đúng tên module.", mod.length ? mod : @"UnityFramework"];
    uintptr_t addr = base + off;
    [trace appendFormat:@"• module base 0x%lX + 0x%lX = 0x%lX\n", (unsigned long)base, (unsigned long)off, (unsigned long)addr];
    for (id p in chain) {
        uintptr_t po = 0;
        if (![p isKindOfClass:[NSString class]] || !ParseHexStrict((NSString *)p, &po)) return @"'pointers' phải là mảng chuỗi hex.";
        uintptr_t next = 0;
        if (!MemRead(addr, &next, sizeof(next)) || next < 0x10000) {
            [trace appendFormat:@"• đọc con trỏ tại 0x%lX thất bại\n", (unsigned long)addr];
            return @"Chuỗi pointer lỗi: không đọc được con trỏ.";
        }
        addr = next + po;
        [trace appendFormat:@"• con trỏ → 0x%lX, +0x%lX = 0x%lX\n", (unsigned long)next, (unsigned long)po, (unsigned long)addr];
    }
    *outAddr = addr;
    *outDesc = [NSString stringWithFormat:@"%@+0x%lX", mod.length ? mod : @"module", (unsigned long)off];
    return nil;
}

// op "near": xem các giá trị quanh một địa chỉ (chỉ ĐỌC, không phải công cụ quét toàn bộ RAM)
static NSString *NearView(uintptr_t addr, NSDictionary *d, NSString *desc, NSString *trace) {
    uintptr_t range = 0x80;
    id rv = d[@"range"];
    if ([rv isKindOfClass:[NSString class]]) { uintptr_t r = 0; if (ParseHexStrict((NSString *)rv, &r)) range = r; }
    else if (rv) { double x = 0; if (ParseNumber(rv, &x) && x > 0) range = (uintptr_t)x; }
    if (range < 8) range = 8;
    if (range > 0x400) range = 0x400;
    range &= ~(uintptr_t)3;
    id fv = d[@"filter"];
    BOOL colorOnly = [fv isKindOfClass:[NSString class]] && [[(NSString *)fv lowercaseString] isEqualToString:@"float01"];

    uint8_t buf[0x800];
    uintptr_t start = addr - range;
    size_t len = range * 2;
    BOOL ok = MemRead(start, buf, len);
    if (!ok) { start = addr; len = range; ok = MemRead(start, buf, len); }   // phương án phụ: chỉ đọc phía sau
    while (!ok && len > 16) { len /= 2; ok = MemRead(start, buf, len); }
    if (!ok) return [NSString stringWithFormat:@"❌ Không đọc được vùng quanh 0x%lX.\n%@", (unsigned long)addr, trace];

    NSMutableString *out = [NSMutableString stringWithFormat:@"📖 Xem gần %@ @%p (±0x%lX, kiểu 4 byte)%@\n",
                            desc, (void *)addr, (unsigned long)range, colorOnly ? @" - lọc cụm float 0..1" : @""];
    size_t slots = len / 4;
    int lines = 0;
    if (colorOnly) {
        size_t i = 0;
        while (i < slots && lines < 30) {
            float f; memcpy(&f, buf + i * 4, 4);
            BOOL in01 = std::isfinite(f) && f >= 0.0f && f <= 1.0f;
            if (!in01) { i++; continue; }
            size_t j = i;
            while (j < slots) { float g; memcpy(&g, buf + j * 4, 4); if (!(std::isfinite(g) && g >= 0.0f && g <= 1.0f)) break; j++; }
            size_t runLen = j - i;
            BOOL allSame = YES; float first = f;
            for (size_t k = i; k < j; k++) { float g; memcpy(&g, buf + k * 4, 4); if (g != first) { allSame = NO; break; } }
            if (runLen >= 3 && !allSame) {
                NSMutableArray<NSString *> *vals = [NSMutableArray array];
                for (size_t k = i; k < j && k < i + 6; k++) { float g; memcpy(&g, buf + k * 4, 4); [vals addObject:[NSString stringWithFormat:@"%.3g", (double)g]]; }
                long rel = (long)((start + i * 4) - addr);
                [out appendFormat:@"  %+ld (0x%lX): %zu float liền nhau: %@\n", rel, (unsigned long)(start + i * 4), runLen, [vals componentsJoinedByString:@", "]];
                lines++;
            }
            i = j;
        }
    } else {
        for (size_t i = 0; i < slots && lines < 64; i++) {
            float f; int32_t iv;
            memcpy(&f, buf + i * 4, 4); memcpy(&iv, buf + i * 4, 4);
            long rel = (long)((start + i * 4) - addr);
            BOOL plausible = std::isfinite(f) && std::fabs(f) < 1e9f && (f == 0.0f || std::fabs(f) > 1e-6f);
            [out appendFormat:@"  %+ld: float=%@  int=%d\n", rel, plausible ? [NSString stringWithFormat:@"%g", (double)f] : @"—", (int)iv];
            lines++;
        }
    }
    if (lines == 0) [out appendString:@"  (không có giá trị phù hợp bộ lọc)\n"];
    return out;
}

// Hoàn tác: mỗi mục lưu trữ có một ngăn xếp các lần áp dụng (chỉ có hiệu lực trong phiên chạy hiện tại)
static NSMutableDictionary<NSString *, NSMutableArray<NSArray *> *> *gUndo = nil;

static NSString *ApplyOne(NSDictionary *d, NSMutableArray *batch) {
    NSString *type = d[@"type"] ? [[d[@"type"] description] lowercaseString] : @"int";
    NSString *op = d[@"op"] ? [[d[@"op"] description] lowercaseString] : @"write";
    NSMutableString *trace = [NSMutableString string];

    uintptr_t addr = 0;
    NSString *desc = nil;
    NSString *err = ResolveAddress(d, &addr, &desc, trace);
    if (err) return [NSString stringWithFormat:@"❌ %@%@", err, trace.length ? [@"\n" stringByAppendingString:trace] : @""];
    if (addr < 0x10000) return @"❌ Địa chỉ không hợp lệ.";

    if ([op isEqualToString:@"near"]) return NearView(addr, d, desc, trace);

    BOOL readOnly = [op isEqualToString:@"read"];
    uint8_t oldBuf[64], newBuf[64], expBuf[64];
    memset(oldBuf, 0, sizeof(oldBuf)); memset(newBuf, 0, sizeof(newBuf)); memset(expBuf, 0, sizeof(expBuf));
    size_t n = 0;
    NSString *verr = nil;

    if ([type isEqualToString:@"all"]) {
        if (!readOnly) return @"❌ Kiểu 'all' chỉ dùng với op 'read'.";
        n = 8;
    } else if ([type isEqualToString:@"bytes"] && readOnly) {
        double len = 16;
        if (d[@"length"] && !ParseNumber(d[@"length"], &len)) return @"❌ 'length' không hợp lệ.";
        if (len < 1 || len > 64) return @"❌ 'length' phải từ 1 đến 64.";
        n = (size_t)len;
    } else if (readOnly) {
        n = TypeSize(type);
        if (n == 0) return [NSString stringWithFormat:@"❌ Kiểu '%@' không hỗ trợ.", type];
    } else {
        if (!BuildValueBytes(type, d[@"value"], newBuf, &n, &verr)) return [@"❌ " stringByAppendingString:verr ? verr : @"Giá trị không hợp lệ."];
    }
    if (n == 0 || n > 64) return @"❌ Kích thước dữ liệu không hợp lệ.";

    BOOL hasExpect = (!readOnly && d[@"expect"] != nil);
    double tol = 1e-3;
    if (d[@"tolerance"]) { double t = 0; if (ParseNumber(d[@"tolerance"], &t) && t >= 0) tol = t; }
    if (hasExpect) {
        size_t en = 0;
        if (!BuildValueBytes(type, d[@"expect"], expBuf, &en, &verr)) return [@"❌ expect: " stringByAppendingString:verr ? verr : @"không hợp lệ."];
        if (en != n) return @"❌ expect không cùng kích thước với value.";
    }

    if (!MemRead(addr, oldBuf, n)) {
        return [NSString stringWithFormat:@"❌ Địa chỉ %p không đọc được, đã hủy (không ghi gì).\n%@", (void *)addr, trace];
    }
    NSString *oldStr = FormatValue(oldBuf, n, type);
    if (readOnly) {
        NSString *shown = [type isEqualToString:@"all"] ? FormatAll(oldBuf) : oldStr;
        return [NSString stringWithFormat:@"📖 %@ @%p = %@ (%@)\n%@", desc, (void *)addr, shown, type, trace];
    }

    if (hasExpect && !ValuesMatch(type, oldBuf, expBuf, n, tol)) {
        return [NSString stringWithFormat:@"⛔ Không ghi: %@ hiện = %@, kỳ vọng %@ (chốt chặn expect). Có thể đối tượng đã đổi hoặc sai trường.", desc, oldStr, FormatValue(expBuf, n, type)];
    }

    NSString *newStr = FormatValue(newBuf, n, type);
    NSString *tag = OpBegin([NSString stringWithFormat:@"GHI %@ %@ → %@", desc, oldStr, newStr]);
    if (!MemWrite(addr, newBuf, n)) {
        OpEnd(tag, @"ghi thất bại");
        return [NSString stringWithFormat:@"❌ Ghi thất bại tại %p (trang bộ nhớ bị khóa?). %@ vẫn = %@.", (void *)addr, desc, oldStr];
    }
    uint8_t chk[64];
    memset(chk, 0, sizeof(chk));
    BOOL verified = MemRead(addr, chk, n) && memcmp(chk, newBuf, n) == 0;

    if (batch && verified) {
        [batch addObject:@{@"recipe": d, @"type": type, @"addr": @((unsigned long long)addr),
                           @"old": [NSData dataWithBytes:oldBuf length:n], @"new": [NSData dataWithBytes:newBuf length:n]}];
    }

    // Kiểm tra trễ: game có đưa giá trị về cũ không? Lệnh chỉ được coi là xong sau bước này.
    NSData *newData = [NSData dataWithBytes:newBuf length:n];
    size_t nn = n;
    NSString *typeCopy = [type copy];
    NSString *descCopy = [desc copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        uint8_t cur[64];
        memset(cur, 0, sizeof(cur));
        NSString *msg;
        BOOL bad = NO;
        if (!MemRead(addr, cur, nn)) {
            msg = [NSString stringWithFormat:@"⚠️ Sau 2 giây không đọc lại được %@.", descCopy];
            bad = YES;
        } else if (memcmp(cur, newData.bytes, nn) == 0) {
            msg = [NSString stringWithFormat:@"✅ Sau 2 giây %@ vẫn giữ giá trị mới.", descCopy];
        } else {
            msg = [NSString stringWithFormat:@"⚠️ Sau 2 giây game đã đưa %@ về %@ (game ghi đè lại).", descCopy, FormatValue(cur, nn, typeCopy)];
            bad = YES;
        }
        OpEnd(tag, msg);
        UILog(msg);
        if (bad) UINotify(msg);
    });

    if (verified) return [NSString stringWithFormat:@"✅ %@ @%p: %@ → %@ (%@, đã xác minh)", desc, (void *)addr, oldStr, newStr, type];
    return [NSString stringWithFormat:@"⚠️ %@ @%p: đã ghi %@ nhưng đọc lại không khớp (game có thể ghi đè lại giá trị).", desc, (void *)addr, newStr];
}

// Nhận một đối tượng JSON hoặc một mảng đối tượng. itemId (nếu có) để ghi nhớ hoàn tác.
static NSString *ApplyPatchJSON(NSString *json, NSString *itemId) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableArray *batch = itemId ? [NSMutableArray array] : nil;
    NSString *result = nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        result = ApplyOne((NSDictionary *)obj, batch);
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSUInteger idx = 0;
        for (id item in (NSArray *)obj) {
            idx++;
            if ([item isKindOfClass:[NSDictionary class]]) {
                [lines addObject:[NSString stringWithFormat:@"#%lu %@", (unsigned long)idx, ApplyOne((NSDictionary *)item, batch)]];
            } else {
                [lines addObject:[NSString stringWithFormat:@"#%lu ❌ Phần tử không phải đối tượng JSON.", (unsigned long)idx]];
            }
        }
        result = lines.count ? [lines componentsJoinedByString:@"\n"] : @"❌ Mảng patch rỗng.";
    } else {
        result = @"❌ JSON patch không hợp lệ.";
    }
    if (itemId && batch.count > 0) {
        if (!gUndo) gUndo = [NSMutableDictionary dictionary];
        NSMutableArray<NSArray *> *stack = gUndo[itemId];
        if (!stack) { stack = [NSMutableArray array]; gUndo[itemId] = stack; }
        [stack addObject:[batch copy]];
        while (stack.count > 10) [stack removeObjectAtIndex:0];
    }
    return result;
}

// Hoàn tác lần áp dụng gần nhất của một mục. Chỉ ghi lại khi địa chỉ và giá trị hiện tại còn khớp lúc ghi.
static NSString *UndoItem(NSString *itemId) {
    NSMutableArray<NSArray *> *stack = itemId ? gUndo[itemId] : nil;
    if (stack.count == 0) {
        return @"Không có thao tác nào để hoàn tác trong phiên này (hoàn tác chỉ có hiệu lực khi chưa khởi động lại game).";
    }
    NSArray *batch = stack.lastObject;
    [stack removeLastObject];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary *rec in [batch reverseObjectEnumerator]) {
        NSDictionary *recipe = rec[@"recipe"];
        NSString *type = rec[@"type"];
        NSData *oldD = rec[@"old"], *newD = rec[@"new"];
        uintptr_t was = (uintptr_t)[rec[@"addr"] unsignedLongLongValue];
        size_t n = oldD.length;
        if (n == 0 || n > 64 || newD.length != n) { [lines addObject:@"❌ Bản ghi hoàn tác hỏng."]; continue; }
        uintptr_t addr = 0;
        NSString *desc = nil;
        NSMutableString *trace = [NSMutableString string];
        NSString *err = ResolveAddress(recipe, &addr, &desc, trace);
        if (err) { [lines addObject:[NSString stringWithFormat:@"❌ Không hoàn tác được: %@", err]]; continue; }
        if (addr != was) { [lines addObject:[NSString stringWithFormat:@"⛔ %@: đối tượng đã đổi chỗ so với lúc ghi, không hoàn tác để tránh sập.", desc]]; continue; }
        uint8_t cur[64];
        memset(cur, 0, sizeof(cur));
        if (!MemRead(addr, cur, n)) { [lines addObject:[NSString stringWithFormat:@"❌ %@: không đọc được địa chỉ.", desc]]; continue; }
        if (memcmp(cur, newD.bytes, n) != 0) {
            [lines addObject:[NSString stringWithFormat:@"⛔ %@: giá trị hiện tại (%@) khác giá trị đã ghi (%@), game đã đổi nên không hoàn tác.", desc, FormatValue(cur, n, type), FormatValue((const uint8_t *)newD.bytes, n, type)]];
            continue;
        }
        NSString *tag = OpBegin([NSString stringWithFormat:@"HOÀN TÁC %@", desc]);
        BOOL ok = MemWrite(addr, oldD.bytes, n);
        uint8_t chk[64];
        memset(chk, 0, sizeof(chk));
        BOOL verified = ok && MemRead(addr, chk, n) && memcmp(chk, oldD.bytes, n) == 0;
        OpEnd(tag, verified ? @"ok" : @"lỗi");
        [lines addObject:verified ? [NSString stringWithFormat:@"↩️ %@: đã trả về %@", desc, FormatValue((const uint8_t *)oldD.bytes, n, type)]
                                  : [NSString stringWithFormat:@"❌ %@: hoàn tác không thành công.", desc]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - AI (Gemini / Claude)

static NSString *AIMOLSystemRules(void) {
    return
    @"Bạn là AIMOL, trợ lý modding chạy ngay trong game trên iPhone. QUY TẮC BẮT BUỘC:\n"
    @"1) CHẾ ĐỘ CHỜ: chỉ trả lời khi người dùng bấm Gửi. Không tự khởi xướng hội thoại.\n"
    @"2) CHỈ NÓI VỀ GAME: game, vật lý 3D, thông số xe, bộ nhớ RAM, kết quả Dump và kỹ thuật modding. Câu hỏi ngoài chủ đề: từ chối ngắn gọn, lịch sự.\n"
    @"3) Mỗi câu trả lời gồm phần giải thích và toàn bộ số liệu/thông số vật lý chi tiết mà bạn đã tính.\n"
    @"4) Bạn nhận ảnh chụp màn hình game (nếu có) và [DUMP CACHE] gồm class, field (kiểu, offset), method (RVA). CHỈ dùng tên class/field/method có trong dữ liệu Dump. "
    @"Nếu thiếu dữ liệu, hãy nói rõ là thiếu và bảo người dùng bấm DUMP METADATA. Tuyệt đối không bịa tên hay offset. Địa chỉ bộ nhớ đổi mỗi lần khởi động, vào trận hay ra sảnh, nên KHÔNG BAO GIỜ đưa địa chỉ tuyệt đối; "
    @"chỉ dùng điểm neo (class + static field) cộng offset field, hoặc module + offset.\n"
    @"5) Khi đề xuất thao tác bộ nhớ, đặt JSON trong khối ```json (một đối tượng hoặc một mảng). Có hai cách:\n"
    @"   A. Theo đối tượng (ưu tiên): {\"class\":\"Namespace.Class\",\"static_field\":\"Instance\",\"pointers\":[\"0x28\"],\"field\":\"tenField\",\"type\":\"float\",\"value\":1.5,\"expect\":1.0}\n"
    @"      - 'static_field' là field static (có trong Dump) chứa đối tượng singleton của class đó.\n"
    @"      - 'pointers' (tùy chọn) là danh sách offset của các field tham chiếu cần đi theo, lần lượt từ đối tượng đó.\n"
    @"      - 'field' là tên field cần ghi (offset tự tính); có thể thay bằng \"offset\":\"0x..\". 'field_class' (tùy chọn) nếu field thuộc class khác.\n"
    @"   B. Theo module (chỉ khi đã biết địa chỉ tính từ đầu module, ví dụ dữ liệu toàn cục): {\"module\":\"auto\",\"offset\":\"0x...\",\"pointers\":[],\"type\":\"float\",\"value\":1.0}\n"
    @"   type: float, float2, float3, float4 (value là mảng số, ví dụ [0.2,0.5,0.9]), double, int, long, bool hoặc bytes (value là chuỗi hex).\n"
    @"   op (tùy chọn): \"read\" chỉ đọc giá trị hiện tại (type \"all\" hiện cùng lúc float, int, double, long, hex); \"near\" xem các giá trị quanh địa chỉ (\"range\":\"0x80\" tối đa 0x400, \"filter\":\"float01\" để lọc cụm float trong khoảng 0 đến 1, hợp để tìm màu).\n"
    @"   expect (tùy chọn nhưng NÊN CÓ khi biết giá trị hiện tại): chỉ ghi nếu giá trị hiện tại khớp, tránh ghi sai chỗ làm sập game. 'tolerance' là sai số cho float (mặc định 0.001).\n"
    @"   Nên đọc (op read hoặc near) trước, rồi mới ghi. Nhiều trường liên quan (ví dụ giá trị hiển thị và dữ liệu thực của xe) thì đưa vào một mảng.\n"
    @"   Màu thường là cụm float liên tiếp trong khoảng 0 đến 1 và phải ghi cả cụm bằng float3 hoặc float4. Thông số xe có thể có hai bộ (hiển thị và thực): kiểm tra cả hai trong Dump.\n"
    @"   LƯU Ý: offset của field trong Dump là offset TRONG đối tượng, KHÔNG phải địa chỉ từ đầu module. Nếu không có static_field phù hợp, hãy nói rõ thay vì đoán.\n"
    @"6) Script JS đặt trong khối ```js (chỉ chạy được với game HTML5/WKWebView). Giao diện HTML đặt trong khối ```html; "
    @"trang HTML gọi window.webkit.messageHandlers.aimol.postMessage(JSON.stringify(patch)) để áp dụng patch và định nghĩa window.aimolResult=function(text){...} để nhận kết quả.\n"
    @"7) Ghi sai kiểu dữ liệu có thể làm văng game: hãy đề xuất giá trị vừa phải và nêu rủi ro nếu có. Nếu game ghi đè lại giá trị (thường ở sảnh), hãy nói rõ là cách này không bền.";
}

static NSString *ErrMsg(id j) {
    @try {
        NSString *m = j[@"error"][@"message"];
        if ([m isKindOfClass:[NSString class]]) return m;
    } @catch (NSException *ex) {}
    return nil;
}

static void AskAI(NSInteger provider, NSString *key, NSString *prompt, NSString *b64,
                  NSArray<NSDictionary *> *history, void (^done)(NSString *, BOOL)) {
    NSMutableURLRequest *req = nil;
    NSDictionary *body = nil;
    if (provider == 0) {
        NSString *url = [NSString stringWithFormat:@"https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent", kGeminiModel];
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        [req setValue:key forHTTPHeaderField:@"x-goog-api-key"];
        NSMutableArray *contents = [NSMutableArray array];
        for (NSDictionary *h in history) {
            [contents addObject:@{@"role": @"user", @"parts": @[@{@"text": h[@"q"]}]}];
            [contents addObject:@{@"role": @"model", @"parts": @[@{@"text": h[@"a"]}]}];
        }
        NSMutableArray *parts = [NSMutableArray arrayWithObject:@{@"text": prompt}];
        if (b64.length) [parts addObject:@{@"inline_data": @{@"mime_type": @"image/jpeg", @"data": b64}}];
        [contents addObject:@{@"role": @"user", @"parts": parts}];
        body = @{@"system_instruction": @{@"parts": @[@{@"text": AIMOLSystemRules()}]},
                 @"contents": contents,
                 @"generationConfig": @{@"maxOutputTokens": @8192}};
    } else {
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.anthropic.com/v1/messages"]];
        [req setValue:key forHTTPHeaderField:@"x-api-key"];
        [req setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
        NSMutableArray *messages = [NSMutableArray array];
        for (NSDictionary *h in history) {
            [messages addObject:@{@"role": @"user", @"content": h[@"q"]}];
            [messages addObject:@{@"role": @"assistant", @"content": h[@"a"]}];
        }
        NSMutableArray *content = [NSMutableArray array];
        if (b64.length) {
            [content addObject:@{@"type": @"image",
                                 @"source": @{@"type": @"base64", @"media_type": @"image/jpeg", @"data": b64}}];
        }
        [content addObject:@{@"type": @"text", @"text": prompt}];
        [messages addObject:@{@"role": @"user", @"content": content}];
        body = @{@"model": kClaudeModel, @"max_tokens": @4096, @"system": AIMOLSystemRules(), @"messages": messages};
    }
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 90;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSString *out = nil;
            BOOL ok = NO;
            if (err) {
                out = [NSString stringWithFormat:@"❌ Lỗi mạng: %@", err.localizedDescription];
            } else {
                NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
                id j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                NSMutableString *text = [NSMutableString string];
                @try {
                    if (provider == 0) {
                        NSArray *parts = j[@"candidates"][0][@"content"][@"parts"];
                        for (id p in parts) {
                            NSString *t = p[@"text"];
                            if ([t isKindOfClass:[NSString class]]) [text appendString:t];
                        }
                    } else {
                        NSArray *content = j[@"content"];
                        for (id c in content) {
                            if ([c[@"type"] isEqual:@"text"]) {
                                NSString *t = c[@"text"];
                                if ([t isKindOfClass:[NSString class]]) [text appendString:t];
                            }
                        }
                    }
                } @catch (NSException *ex) {
                    [text setString:@""];
                }
                if (text.length > 0 && code >= 200 && code < 300) {
                    out = text;
                    ok = YES;
                } else {
                    NSString *em = ErrMsg(j);
                    if (!em) {
                        NSString *raw = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                        em = raw.length > 500 ? [raw substringToIndex:500] : raw;
                    }
                    out = [NSString stringWithFormat:@"❌ Lỗi API (HTTP %ld): %@", (long)code, em];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ done(out, ok); });
        }];
    [task resume];
}

#pragma mark - Ảnh chụp màn hình

static BOOL ImageLooksBlack(UIImage *img) {
    CGImageRef cg = img.CGImage;
    if (!cg) return YES;
    const int N = 16;
    uint8_t px[N * N * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo info = (CGBitmapInfo)((uint32_t)kCGImageAlphaPremultipliedLast | (uint32_t)kCGBitmapByteOrder32Big);
    CGContextRef c = CGBitmapContextCreate(px, N, N, 8, N * 4, cs, info);
    CGColorSpaceRelease(cs);
    if (!c) return NO;
    CGContextDrawImage(c, CGRectMake(0, 0, N, N), cg);
    CGContextRelease(c);
    unsigned long sum = 0;
    for (int i = 0; i < N * N; i++) sum += (unsigned long)px[i * 4] + px[i * 4 + 1] + px[i * 4 + 2];
    return (sum / (unsigned long)(N * N * 3)) < 4;
}

#pragma mark - Tiêu đề cho Khu lưu trữ

static NSString *TitleForCode(NSString *kind, NSString *code) {
    NSString *title = nil;
    if ([kind isEqualToString:@"patch"]) {
        NSData *data = [code dataUsingEncoding:NSUTF8StringEncoding];
        id j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSUInteger extra = 0;
        NSDictionary *d = nil;
        if ([j isKindOfClass:[NSArray class]]) {
            NSArray *a = (NSArray *)j;
            if (a.count > 0 && [a[0] isKindOfClass:[NSDictionary class]]) d = a[0];
            extra = a.count > 0 ? a.count - 1 : 0;
        } else if ([j isKindOfClass:[NSDictionary class]]) {
            d = (NSDictionary *)j;
        }
        if (d) {
            NSString *cls = [d[@"class"] isKindOfClass:[NSString class]] ? d[@"class"] : nil;
            NSString *fld = [d[@"field"] isKindOfClass:[NSString class]] ? d[@"field"] : nil;
            NSString *off = [d[@"offset"] isKindOfClass:[NSString class]] ? d[@"offset"] : nil;
            id vraw = d[@"value"];
            NSString *val = @"?";
            if ([vraw isKindOfClass:[NSArray class]]) {
                NSMutableArray<NSString *> *parts = [NSMutableArray array];
                for (id e in (NSArray *)vraw) [parts addObject:[e description]];
                val = [NSString stringWithFormat:@"(%@)", [parts componentsJoinedByString:@", "]];
            } else if (vraw) {
                val = [vraw description];
            }
            BOOL isRead = [[d[@"op"] description] isEqualToString:@"read"];
            NSString *target = cls ? [NSString stringWithFormat:@"%@.%@", cls, fld ? fld : (off ? off : @"?")] : (off ? off : @"?");
            BOOL isNear = [[d[@"op"] description] isEqualToString:@"near"];
            title = isNear ? [NSString stringWithFormat:@"XEM GẦN %@", target]
                  : (isRead ? [NSString stringWithFormat:@"ĐỌC %@", target] : [NSString stringWithFormat:@"%@ = %@", target, val]);
            if (extra > 0) title = [title stringByAppendingFormat:@" (+%lu)", (unsigned long)extra];
        }
    } else if ([kind isEqualToString:@"html"]) {
        NSRange a = [code rangeOfString:@"<title>" options:NSCaseInsensitiveSearch];
        NSRange b = [code rangeOfString:@"</title>" options:NSCaseInsensitiveSearch];
        if (a.location != NSNotFound && b.location != NSNotFound && b.location > NSMaxRange(a)) {
            title = Trim([code substringWithRange:NSMakeRange(NSMaxRange(a), b.location - NSMaxRange(a))]);
        }
    }
    if (title.length == 0) {
        for (NSString *line in [code componentsSeparatedByString:@"\n"]) {
            NSString *t = Trim(line);
            if (t.length > 0) { title = t; break; }
        }
    }
    if (title.length == 0) title = @"(trống)";
    if (title.length > 48) title = [title substringToIndex:48];
    return [NSString stringWithFormat:@"[%@] %@", [kind uppercaseString], title];
}

#pragma mark - Tra cứu Dump (đọc thẳng file, không nạp cả file vào RAM)

static BOOL ParseClassDecl(const char *line, char *outName, size_t cap) {
    const char *kws[4] = {"class ", "struct ", "enum ", "interface "};
    for (int i = 0; i < 4; i++) {
        const char *p = strstr(line, kws[i]);
        if (p && (p == line || *(p - 1) == ' ')) {
            p += strlen(kws[i]);
            size_t n = 0;
            while (*p && *p != ' ' && *p != ':' && *p != '\n' && *p != '\r' && n + 1 < cap) outName[n++] = *p++;
            outName[n] = '\0';
            return n > 0;
        }
    }
    return NO;
}

static NSArray<NSDictionary *> *SearchDumpFile(NSString *path, NSString *query, BOOL (^cancelled)(void)) {
    const char *needle = query.UTF8String;
    if (!needle || !*needle) return @[];
    FILE *fp = fopen(path.fileSystemRepresentation, "r");
    if (!fp) return @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    char line[4096];
    char cls[256];
    cls[0] = '\0';
    unsigned long lineNo = 0;
    while (fgets(line, sizeof(line), fp) != NULL) {
        if ((++lineNo & 0x1FFF) == 0 && cancelled()) break;
        char c0 = line[0];
        if (c0 == '\t') {
            if (line[1] == '/') continue;                    // dòng chú thích "// Fields"
            if (strcasestr(line, needle) == NULL) continue;
            NSString *ln = Trim(CStr(line));
            if (ln.length == 0) continue;
            [out addObject:@{@"t": [NSString stringWithFormat:@"%s › %@", cls, ln],
                             @"c": [NSString stringWithFormat:@"%s :: %@", cls, ln]}];
        } else if (c0 != '/' && c0 != '{' && c0 != '}' && c0 != '\n' && c0 != '\r' && c0 != '\0') {
            char name[256];
            if (ParseClassDecl(line, name, sizeof(name))) {
                strncpy(cls, name, sizeof(cls) - 1);
                cls[sizeof(cls) - 1] = '\0';
                if (strcasestr(line, needle) != NULL) {
                    NSString *ln = Trim(CStr(line));
                    [out addObject:@{@"t": ln, @"c": ln}];
                }
            }
        }
        if (out.count >= kMaxSearchResults) break;
    }
    fclose(fp);
    return out;
}

#pragma mark - Giao diện Overlay (UIKit)

static UIButton *MakeBubble(NSString *title, UIColor *border) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 56, 56);
    b.backgroundColor = [UIColor blackColor];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    b.titleLabel.textAlignment = NSTextAlignmentCenter;
    b.layer.cornerRadius = 28;
    b.layer.borderColor = border.CGColor;
    b.layer.borderWidth = 1;
    return b;
}

static UIButton *TextButton(NSString *title, CGFloat size, BOOL bold) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    return b;
}

@interface AIMOLUI : NSObject <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, WKScriptMessageHandler, PHPickerViewControllerDelegate>
// --- Nút nổi và bảng chính ---
@property (nonatomic, strong) UIButton *floatBtn;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *hdr;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *logBtn;
@property (nonatomic, strong) UIButton *shareBtn;
@property (nonatomic, strong) UIButton *dumpBtn;
@property (nonatomic, strong) UISegmentedControl *tabSeg;
@property (nonatomic, strong) UIView *tabChat;
@property (nonatomic, strong) UISegmentedControl *provSeg;
@property (nonatomic, strong) UITextField *geminiKey;
@property (nonatomic, strong) UITextField *claudeKey;
@property (nonatomic, strong) UITextView *chat;
@property (nonatomic, strong) UIView *swRow;
@property (nonatomic, strong) UISwitch *swImg;
@property (nonatomic, strong) UISwitch *swDump;
@property (nonatomic, strong) UILabel *lblImg;
@property (nonatomic, strong) UILabel *lblDump;
@property (nonatomic, strong) UITextField *input;
@property (nonatomic, strong) UIButton *sendBtn;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIView *tabTools;
@property (nonatomic, strong) UIButton *designRowBtn;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UITableView *resultsTable;
@property (nonatomic, strong) UILabel *resultsHint;
@property (nonatomic, strong) UIView *previewBox;
// --- Design ---
@property (nonatomic, strong) UIButton *designBtn;
@property (nonatomic, strong) UIView *dpanel;
@property (nonatomic, strong) UIView *dbar;
@property (nonatomic, strong) UILabel *dtitle;
@property (nonatomic, strong) UIButton *dxBtn;
@property (nonatomic, strong) UIView *dview;
@property (nonatomic, strong) UIImageView *dimage;
@property (nonatomic, strong) UIView *dempty;
@property (nonatomic, strong) UILabel *demptyLabel;
@property (nonatomic, strong) UIButton *dpick;
@property (nonatomic, strong) UIButton *dpaste;
@property (nonatomic, strong) UIView *dctl;
@property (nonatomic, strong) UIButton *dminus;
@property (nonatomic, strong) UIButton *dplus;
@property (nonatomic, strong) UILabel *dzoom;
@property (nonatomic, strong) UIButton *dchange;
@property (nonatomic, strong) UILabel *dopLabel;
@property (nonatomic, strong) UISlider *dslider;
@property (nonatomic, strong) UIView *dhandle;
// --- Thông báo ---
@property (nonatomic, strong) UIView *notifyView;
@property (nonatomic, strong) UILabel *notifyTitle;
@property (nonatomic, strong) UILabel *notifyLabel;
// --- Dữ liệu ---
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *patches;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *history;
@property (nonatomic, strong) NSArray<NSDictionary *> *searchResults;
@property (nonatomic, strong) NSTimer *watchdog;
// --- Trạng thái ---
@property (nonatomic) CGSize lastWinSize;
@property (nonatomic) CGPoint panelOrigin;
@property (nonatomic) CGRect dFrame;
@property (nonatomic) CGFloat dOpacity;
@property (nonatomic) CGFloat kbTop;
@property (nonatomic) NSInteger notifyToken;
@property (nonatomic) NSInteger searchToken;
@property (nonatomic) BOOL hasPanelOrigin;
@property (nonatomic) BOOL hasDFrame;
@property (nonatomic) BOOL dumping;
@property (nonatomic) BOOL installed;
@property (nonatomic) BOOL keyboardUp;
@property (nonatomic) BOOL designActive;
@property (nonatomic) BOOL designOpen;
+ (instancetype)shared;
- (void)install;
- (void)log:(NSString *)s;
- (void)showNotice:(NSString *)text seconds:(NSTimeInterval)sec force:(BOOL)force;
@end

@implementation AIMOLUI

+ (instancetype)shared {
    static AIMOLUI *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[AIMOLUI alloc] init];
    });
    return instance;
}

- (UIWindow *)keyWindow {
    // Lượt 1: scene đang hoạt động. Lượt 2: scene bất kỳ. Lượt 3: danh sách cửa sổ của ứng dụng.
    for (int pass = 0; pass < 2; pass++) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            if (pass == 0 && sc.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    UIWindow *fallback = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) return w;
        if (!fallback && !w.hidden) fallback = w;
    }
    return fallback;
}

- (UITextField *)makeField:(NSString *)placeholder secure:(BOOL)secure defaultsKey:(NSString *)dkey {
    UITextField *t = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    t.placeholder = placeholder;
    t.secureTextEntry = secure;
    t.borderStyle = UITextBorderStyleRoundedRect;
    t.font = [UIFont systemFontOfSize:13];
    t.autocapitalizationType = UITextAutocapitalizationTypeNone;
    t.autocorrectionType = UITextAutocorrectionTypeNo;
    t.delegate = self;
    t.returnKeyType = UIReturnKeyDone;
    if (dkey) {
        t.text = [[NSUserDefaults standardUserDefaults] stringForKey:dkey];
        [t addTarget:self action:@selector(saveKeys) forControlEvents:UIControlEventEditingChanged];
    }
    return t;
}

- (void)saveKeys {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:(self.geminiKey.text ? self.geminiKey.text : @"") forKey:@"aimol.gemini"];
    [ud setObject:(self.claudeKey.text ? self.claudeKey.text : @"") forKey:@"aimol.claude"];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.input) {
        [self onSend];
    } else {
        [textField resignFirstResponder];
    }
    return YES;
}

#pragma mark Hình học

- (CGSize)basePanelSize {
    UIWindow *w = [self keyWindow];
    if (!w) return CGSizeMake(340, 300);
    CGRect b = w.bounds;
    UIEdgeInsets in = w.safeAreaInsets;
    BOOL land = b.size.width > b.size.height;
    CGFloat availW = b.size.width - in.left - in.right - 16;
    CGFloat availH = b.size.height - in.top - in.bottom - 16;
    CGFloat pw = MIN(availW, land ? (CGFloat)520 : (CGFloat)420);
    CGFloat ph = land ? availH : MIN(availH, b.size.height * (CGFloat)0.55);
    return CGSizeMake(pw, ph);
}

- (CGRect)clampRect:(CGRect)r {
    UIWindow *w = [self keyWindow];
    if (!w) return r;
    UIEdgeInsets in = w.safeAreaInsets;
    CGRect b = w.bounds;
    CGFloat minX = in.left, maxX = b.size.width - in.right - r.size.width;
    CGFloat minY = in.top, maxY = b.size.height - in.bottom - r.size.height;
    r.origin.x = MIN(MAX(r.origin.x, minX), MAX(minX, maxX));
    r.origin.y = MIN(MAX(r.origin.y, minY), MAX(minY, maxY));
    return r;
}

- (CGRect)desiredPanelFrame {
    UIWindow *w = [self keyWindow];
    CGSize s = [self basePanelSize];
    CGRect b = w ? w.bounds : CGRectMake(0, 0, 390, 844);
    UIEdgeInsets in = w ? w.safeAreaInsets : UIEdgeInsetsMake(0, 0, 0, 0);
    BOOL land = b.size.width > b.size.height;
    CGPoint o = self.hasPanelOrigin
        ? self.panelOrigin
        : CGPointMake(in.left + 8 + (b.size.width - in.left - in.right - 16 - s.width) / 2, in.top + (land ? (CGFloat)8 : (CGFloat)60));
    return [self clampRect:CGRectMake(o.x, o.y, s.width, s.height)];
}

- (void)applyPanelFrame {
    CGRect f = [self desiredPanelFrame];
    UIWindow *w = [self keyWindow];
    if (self.keyboardUp && w) {
        CGFloat maxBottom = self.kbTop - 6;
        CGFloat h = MAX((CGFloat)170, MIN(f.size.height, maxBottom - f.origin.y));
        f.size.height = h;
        if (CGRectGetMaxY(f) > maxBottom) f.origin.y = MAX(w.safeAreaInsets.top + 4, maxBottom - h);
    }
    self.panel.frame = f;
    [self layoutPanel];
}

- (CGRect)clampDesignFrame:(CGRect)f {
    UIWindow *w = [self keyWindow];
    if (!w) return f;
    UIEdgeInsets in = w.safeAreaInsets;
    CGRect b = w.bounds;
    CGFloat maxW = b.size.width - in.left - in.right - 12;
    CGFloat maxH = b.size.height - in.top - in.bottom - 12;
    f.size.width = MIN(MAX(f.size.width, (CGFloat)150), MAX((CGFloat)150, maxW));
    f.size.height = MIN(MAX(f.size.height, (CGFloat)190), MAX((CGFloat)190, maxH));
    return [self clampRect:f];
}

- (void)clampBubble:(UIView *)v {
    UIWindow *w = [self keyWindow];
    if (!w || !v) return;
    UIEdgeInsets in = w.safeAreaInsets;
    CGRect b = w.bounds;
    CGFloat minX = in.left + 28, maxX = b.size.width - in.right - 28;
    CGFloat minY = in.top + 28, maxY = b.size.height - in.bottom - 28;
    CGPoint c = v.center;
    c.x = MIN(MAX(c.x, minX), MAX(minX, maxX));
    c.y = MIN(MAX(c.y, minY), MAX(minY, maxY));
    v.center = c;
}

- (void)layoutPanel {
    CGFloat pw = self.panel.bounds.size.width;
    CGFloat ph = self.panel.bounds.size.height;
    self.hdr.frame = CGRectMake(0, 0, pw, 40);
    self.titleLabel.frame = CGRectMake(12, 0, 100, 40);
    self.logBtn.frame = CGRectMake(pw - 228, 6, 36, 30);
    self.shareBtn.frame = CGRectMake(pw - 188, 6, 36, 30);
    self.dumpBtn.frame = CGRectMake(pw - 148, 6, 138, 30);
    self.tabSeg.frame = CGRectMake(10, 40, pw - 20, 30);
    CGFloat y0 = 76;
    CGFloat cw = pw - 20;
    CGFloat ch = MAX((CGFloat)120, ph - y0 - 8);
    self.tabChat.frame = CGRectMake(10, y0, cw, ch);
    self.table.frame = CGRectMake(10, y0, cw, ch);
    self.tabTools.frame = CGRectMake(10, y0, cw, ch);
    // CHAT AI
    self.provSeg.frame = CGRectMake(0, 0, cw, 28);
    self.geminiKey.frame = CGRectMake(0, 32, cw / 2 - 2, 30);
    self.claudeKey.frame = CGRectMake(cw / 2 + 2, 32, cw / 2 - 2, 30);
    self.chat.frame = CGRectMake(0, 66, cw, MAX((CGFloat)40, ch - 136));
    self.swRow.frame = CGRectMake(0, ch - 68, cw, 28);
    self.swImg.center = CGPointMake(20, 14);
    self.lblImg.frame = CGRectMake(42, 0, 64, 28);
    self.swDump.center = CGPointMake(126, 14);
    self.lblDump.frame = CGRectMake(148, 0, 80, 28);
    self.input.frame = CGRectMake(0, ch - 34, cw - 64, 32);
    self.sendBtn.frame = CGRectMake(cw - 60, ch - 34, 60, 32);
    // CÔNG CỤ
    self.designRowBtn.frame = CGRectMake(0, 0, cw, 34);
    self.searchField.frame = CGRectMake(0, 40, cw, 30);
    self.resultsTable.frame = CGRectMake(0, 74, cw, MAX((CGFloat)40, ch - 74));
    self.resultsHint.frame = CGRectMake(12, 82, MAX((CGFloat)40, cw - 24), 60);
}

- (void)layoutDesign {
    CGRect f = self.dFrame;
    self.dpanel.frame = f;
    CGFloat w = f.size.width, h = f.size.height;
    self.dbar.frame = CGRectMake(0, 0, w, 32);
    self.dxBtn.frame = CGRectMake(0, 0, 36, 32);
    self.dtitle.frame = CGRectMake(36, 0, MAX((CGFloat)10, w - 72), 32);
    self.dview.frame = CGRectMake(0, 32, w, MAX((CGFloat)40, h - 32 - 74));
    self.dimage.frame = self.dview.bounds;
    self.dempty.frame = self.dview.bounds;
    CGFloat ew = self.dview.bounds.size.width;
    self.demptyLabel.frame = CGRectMake(10, 10, MAX((CGFloat)10, ew - 20), 36);
    CGFloat bw = MAX((CGFloat)40, (ew - 30) / 2);
    self.dpick.frame = CGRectMake(10, 50, bw, 34);
    self.dpaste.frame = CGRectMake(20 + bw, 50, bw, 34);
    self.dctl.frame = CGRectMake(0, h - 74, w, 74);
    self.dminus.frame = CGRectMake(10, 4, 34, 30);
    self.dzoom.frame = CGRectMake(46, 4, 56, 30);
    self.dplus.frame = CGRectMake(104, 4, 34, 30);
    self.dchange.frame = CGRectMake(MAX((CGFloat)140, w - 100), 4, 90, 30);
    self.dopLabel.frame = CGRectMake(10, 40, 54, 28);
    self.dslider.frame = CGRectMake(66, 40, MAX((CGFloat)20, w - 66 - 34), 28);
    self.dhandle.frame = CGRectMake(w - 26, h - 26, 26, 26);
    self.dzoom.text = [NSString stringWithFormat:@"%d%%", (int)lround(f.size.width / 230.0 * 100.0)];
    self.dview.alpha = 1;
    self.dimage.alpha = self.dOpacity;
    self.dpanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:(CGFloat)(0.35 + 0.61 * self.dOpacity)];
    BOOL hasImg = (self.dimage.image != nil);
    self.dempty.hidden = hasImg;
    self.dimage.hidden = !hasImg;
}

- (void)bringOverlayToFront {
    UIWindow *w = [self keyWindow];
    if (!w) return;
    NSArray<UIView *> *order = @[self.panel, self.dpanel, self.previewBox ? self.previewBox : self.panel,
                                 self.notifyView, self.floatBtn, self.designBtn];
    for (UIView *v in order) {
        if (v && v.superview == w) [w bringSubviewToFront:v];
    }
}

#pragma mark Lưu và nạp trạng thái giao diện

- (void)saveUIState {
    if (!self.installed) return;
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"fb"] = NSStringFromCGPoint(self.floatBtn.center);
    if (self.hasPanelOrigin) s[@"po"] = NSStringFromCGPoint(self.panelOrigin);
    s[@"da"] = @(self.designActive);
    s[@"db"] = NSStringFromCGPoint(self.designBtn.center);
    if (self.hasDFrame) s[@"df"] = NSStringFromCGRect(self.dFrame);
    s[@"dop"] = @(self.dOpacity);
    s[@"swi"] = @(self.swImg.on);
    s[@"swd"] = @(self.swDump.on);
    [[NSUserDefaults standardUserDefaults] setObject:s forKey:kUIStateKey];
}

- (NSString *)designImagePath {
    return [DocsDir() stringByAppendingPathComponent:@"AIMOL_design.jpg"];
}

- (void)loadUIState {
    NSDictionary *s = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kUIStateKey];
    UIWindow *w = [self keyWindow];
    CGRect b = w ? w.bounds : CGRectMake(0, 0, 390, 844);
    self.floatBtn.center = CGPointMake(b.size.width - 48, b.size.height * (CGFloat)0.35 + 28);
    self.dOpacity = 1;
    self.swImg.on = YES;
    self.swDump.on = YES;
    if ([s isKindOfClass:[NSDictionary class]]) {
        if ([s[@"fb"] isKindOfClass:[NSString class]]) self.floatBtn.center = CGPointFromString(s[@"fb"]);
        if ([s[@"po"] isKindOfClass:[NSString class]]) { self.panelOrigin = CGPointFromString(s[@"po"]); self.hasPanelOrigin = YES; }
        if ([s[@"db"] isKindOfClass:[NSString class]]) self.designBtn.center = CGPointFromString(s[@"db"]);
        if ([s[@"df"] isKindOfClass:[NSString class]]) { self.dFrame = CGRectFromString(s[@"df"]); self.hasDFrame = YES; }
        if ([s[@"dop"] isKindOfClass:[NSNumber class]]) self.dOpacity = MIN((CGFloat)1, MAX((CGFloat)0.2, [s[@"dop"] doubleValue]));
        if ([s[@"da"] isKindOfClass:[NSNumber class]]) self.designActive = [s[@"da"] boolValue];
        if ([s[@"swi"] isKindOfClass:[NSNumber class]]) self.swImg.on = [s[@"swi"] boolValue];
        if ([s[@"swd"] isKindOfClass:[NSNumber class]]) self.swDump.on = [s[@"swd"] boolValue];
    }
    if (!self.hasDFrame) {
        UIEdgeInsets in = w ? w.safeAreaInsets : UIEdgeInsetsMake(0, 0, 0, 0);
        self.dFrame = CGRectMake(in.left + 10, in.top + 90, 230, 300);
    }
    self.dFrame = [self clampDesignFrame:self.dFrame];
    self.dslider.value = (float)self.dOpacity;
    [self clampBubble:self.floatBtn];
    [self clampBubble:self.designBtn];
    UIImage *img = [UIImage imageWithContentsOfFile:[self designImagePath]];
    if (img) self.dimage.image = img;
}

#pragma mark Dựng giao diện

- (void)install {
    if (self.installed) return;
    UIWindow *w = [self keyWindow];
    if (!w) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self install];
        });
        return;
    }
    self.installed = YES;

    // Nhật ký và kiểm tra phiên trước (đọc TRƯỚC khi mở phiên mới)
    NSString *issue = PreviousSessionIssue();
    NSString *dumpIssue = DumpCheckPrevious();
    AimolLogInit();
    gUILogger = ^(NSString *s) { [[AIMOLUI shared] log:s]; };
    gUINotifier = ^(NSString *s) { [[AIMOLUI shared] showNotice:s seconds:10 force:NO]; };

    // Khu lưu trữ: nạp và bổ sung id, phiên bản cho mục cũ
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kPatchStore];
    self.patches = [[NSMutableArray alloc] init];
    for (id it in saved) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *m = [(NSDictionary *)it mutableCopy];
        if (![m[@"id"] isKindOfClass:[NSString class]]) m[@"id"] = [[NSUUID UUID] UUIDString];
        if (![m[@"ver"] isKindOfClass:[NSString class]]) m[@"ver"] = @"";
        [self.patches addObject:m];
    }
    self.history = [[NSMutableArray alloc] init];
    self.searchResults = @[];

    // ----- Panel chính -----
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 340, 300)];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.98];   // bảng chat KHÔNG làm mờ
    self.panel.layer.cornerRadius = 14;
    self.panel.clipsToBounds = YES;
    self.panel.hidden = YES;
    self.panel.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    // ----- Header (kéo để di chuyển bảng) -----
    self.hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 340, 40)];
    UIPanGestureRecognizer *hdrPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPanPanel:)];
    [self.hdr addGestureRecognizer:hdrPan];
    [self.panel addSubview:self.hdr];
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 100, 40)];
    self.titleLabel.text = @"⠿ AIMOL";
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.hdr addSubview:self.titleLabel];

    self.logBtn = TextButton(@"📋", 17, NO);
    [self.logBtn addTarget:self action:@selector(onLog) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.logBtn];

    self.shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.shareBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    [self.shareBtn addTarget:self action:@selector(onShare) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.shareBtn];

    self.dumpBtn = TextButton(@"DUMP METADATA", 13, YES);
    [self.dumpBtn addTarget:self action:@selector(onDump) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.dumpBtn];

    self.tabSeg = [[UISegmentedControl alloc] initWithItems:@[@"CHAT AI", @"KHU LƯU TRỮ", @"CÔNG CỤ"]];
    self.tabSeg.selectedSegmentIndex = 0;
    [self.tabSeg addTarget:self action:@selector(onTab) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.tabSeg];

    // ----- TAB 1: CHAT AI -----
    self.tabChat = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    self.provSeg = [[UISegmentedControl alloc] initWithItems:@[@"Gemini", @"Claude"]];
    self.provSeg.selectedSegmentIndex = 0;
    self.geminiKey = [self makeField:@"Gemini API Key" secure:YES defaultsKey:@"aimol.gemini"];
    self.claudeKey = [self makeField:@"Claude API Key" secure:YES defaultsKey:@"aimol.claude"];
    self.chat = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    self.chat.editable = NO;
    self.chat.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    self.chat.textColor = [UIColor whiteColor];
    self.chat.font = [UIFont systemFontOfSize:13];
    self.chat.layer.cornerRadius = 8;

    self.swRow = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 28)];
    self.swImg = [[UISwitch alloc] init];
    self.swImg.transform = CGAffineTransformMakeScale((CGFloat)0.75, (CGFloat)0.75);
    self.swDump = [[UISwitch alloc] init];
    self.swDump.transform = CGAffineTransformMakeScale((CGFloat)0.75, (CGFloat)0.75);
    [self.swImg addTarget:self action:@selector(saveUIState) forControlEvents:UIControlEventValueChanged];
    [self.swDump addTarget:self action:@selector(saveUIState) forControlEvents:UIControlEventValueChanged];
    self.lblImg = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    self.lblImg.text = @"Gửi ảnh";
    self.lblImg.font = [UIFont systemFontOfSize:12];
    self.lblImg.textColor = [UIColor whiteColor];
    self.lblDump = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    self.lblDump.text = @"Kèm Dump";
    self.lblDump.font = [UIFont systemFontOfSize:12];
    self.lblDump.textColor = [UIColor whiteColor];
    for (UIView *v in @[self.swImg, self.lblImg, self.swDump, self.lblDump]) [self.swRow addSubview:v];

    self.input = [self makeField:@"Nhập câu hỏi..." secure:NO defaultsKey:nil];
    self.input.returnKeyType = UIReturnKeySend;
    self.sendBtn = TextButton(@"Gửi", 15, NO);
    [self.sendBtn addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    NSArray<UIView *> *chatViews = @[self.provSeg, self.geminiKey, self.claudeKey, self.chat, self.swRow, self.input, self.sendBtn];
    for (UIView *v in chatViews) [self.tabChat addSubview:v];
    [self.panel addSubview:self.tabChat];

    // ----- TAB 2: KHU LƯU TRỮ -----
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, 10, 10) style:UITableViewStylePlain];
    self.table.backgroundColor = [UIColor clearColor];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.hidden = YES;
    [self.panel addSubview:self.table];

    // ----- TAB 3: CÔNG CỤ -----
    self.tabTools = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    self.tabTools.hidden = YES;
    self.designRowBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.designRowBtn.backgroundColor = [UIColor colorWithRed:118.0f/255 green:118.0f/255 blue:128.0f/255 alpha:0.24f];
    self.designRowBtn.layer.cornerRadius = 8;
    self.designRowBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    NSMutableAttributedString *dt = [[NSMutableAttributedString alloc] initWithString:@"◀   Design"];
    [dt addAttribute:NSForegroundColorAttributeName value:[UIColor whiteColor] range:NSMakeRange(0, dt.length)];
    [dt addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:0.04f green:0.52f blue:1.0f alpha:1] range:NSMakeRange(0, 1)];
    [dt addAttribute:NSFontAttributeName value:[UIFont boldSystemFontOfSize:14] range:NSMakeRange(0, dt.length)];
    [self.designRowBtn setAttributedTitle:dt forState:UIControlStateNormal];
    self.designRowBtn.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 0);
    [self.designRowBtn addTarget:self action:@selector(onDesignRow) forControlEvents:UIControlEventTouchUpInside];
    [self.tabTools addSubview:self.designRowBtn];

    self.searchField = [self makeField:@"Tra cứu Dump: tìm class, field, method..." secure:NO defaultsKey:nil];
    [self.searchField addTarget:self action:@selector(onSearchChanged) forControlEvents:UIControlEventEditingChanged];
    [self.tabTools addSubview:self.searchField];

    self.resultsTable = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, 10, 10) style:UITableViewStylePlain];
    self.resultsTable.backgroundColor = [UIColor clearColor];
    self.resultsTable.dataSource = self;
    self.resultsTable.delegate = self;
    [self.tabTools addSubview:self.resultsTable];
    self.resultsHint = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    self.resultsHint.font = [UIFont systemFontOfSize:12];
    self.resultsHint.textColor = [UIColor colorWithWhite:0.6f alpha:1];
    self.resultsHint.numberOfLines = 0;
    self.resultsHint.text = @"Gõ ít nhất 2 ký tự để tìm trong file Dump.";
    [self.tabTools addSubview:self.resultsHint];
    [self.panel addSubview:self.tabTools];

    // ----- Nút nổi AIMOL -----
    self.floatBtn = MakeBubble(@"AIMOL", [UIColor colorWithWhite:0.3f alpha:1]);                       // nền #000000, chữ #FFFFFF
    [self.floatBtn addTarget:self action:@selector(onFloat) forControlEvents:UIControlEventTouchUpInside];
    [self.floatBtn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPanBubble:)]];

    // ----- Cục tròn design (chỉ hiện khi bật từ mục Design) -----
    self.designBtn = MakeBubble(@"design", [UIColor colorWithRed:0.75f green:0.35f blue:0.95f alpha:1]);
    self.designBtn.hidden = YES;
    [self.designBtn addTarget:self action:@selector(onDesignBubbleTap) forControlEvents:UIControlEventTouchUpInside];
    [self.designBtn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPanBubble:)]];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onDesignLong:)];
    lp.minimumPressDuration = 0.65;
    [self.designBtn addGestureRecognizer:lp];

    // ----- Bảng design -----
    self.dpanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 230, 300)];
    self.dpanel.layer.cornerRadius = 12;
    self.dpanel.clipsToBounds = YES;
    self.dpanel.hidden = YES;
    self.dpanel.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.dbar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 230, 32)];
    self.dbar.backgroundColor = [UIColor colorWithWhite:0.24f alpha:0.95f];
    [self.dbar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPanDesignBar:)]];
    [self.dpanel addSubview:self.dbar];
    self.dtitle = [[UILabel alloc] initWithFrame:CGRectMake(36, 0, 158, 32)];
    self.dtitle.text = @"design";
    self.dtitle.textAlignment = NSTextAlignmentCenter;
    self.dtitle.textColor = [UIColor whiteColor];
    self.dtitle.font = [UIFont boldSystemFontOfSize:13];
    [self.dbar addSubview:self.dtitle];
    self.dxBtn = TextButton(@"✕", 16, NO);
    [self.dxBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.dxBtn addTarget:self action:@selector(onDesignClose) forControlEvents:UIControlEventTouchUpInside];
    [self.dpanel addSubview:self.dxBtn];

    self.dview = [[UIView alloc] initWithFrame:CGRectMake(0, 32, 230, 194)];
    self.dview.backgroundColor = [UIColor colorWithWhite:0.07f alpha:1];
    self.dview.clipsToBounds = YES;
    self.dimage = [[UIImageView alloc] initWithFrame:self.dview.bounds];
    self.dimage.contentMode = UIViewContentModeScaleAspectFit;
    [self.dview addSubview:self.dimage];
    self.dempty = [[UIView alloc] initWithFrame:self.dview.bounds];
    self.demptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 210, 36)];
    self.demptyLabel.text = @"Chọn ảnh để bắt đầu";
    self.demptyLabel.textColor = [UIColor colorWithWhite:0.78f alpha:1];
    self.demptyLabel.font = [UIFont systemFontOfSize:13];
    self.demptyLabel.numberOfLines = 2;
    self.demptyLabel.textAlignment = NSTextAlignmentCenter;
    [self.dempty addSubview:self.demptyLabel];
    self.dpick = TextButton(@"Chọn ảnh…", 14, NO);
    [self.dpick addTarget:self action:@selector(onPickImage) forControlEvents:UIControlEventTouchUpInside];
    [self.dempty addSubview:self.dpick];
    self.dpaste = TextButton(@"Dán ảnh", 14, NO);
    [self.dpaste addTarget:self action:@selector(onPasteImage) forControlEvents:UIControlEventTouchUpInside];
    [self.dempty addSubview:self.dpaste];
    [self.dview addSubview:self.dempty];
    [self.dpanel addSubview:self.dview];

    self.dctl = [[UIView alloc] initWithFrame:CGRectMake(0, 226, 230, 74)];
    self.dminus = TextButton(@"−", 20, YES);
    [self.dminus addTarget:self action:@selector(onDesignMinus) forControlEvents:UIControlEventTouchUpInside];
    self.dplus = TextButton(@"+", 20, YES);
    [self.dplus addTarget:self action:@selector(onDesignPlus) forControlEvents:UIControlEventTouchUpInside];
    self.dzoom = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    self.dzoom.textAlignment = NSTextAlignmentCenter;
    self.dzoom.textColor = [UIColor whiteColor];
    self.dzoom.font = [UIFont systemFontOfSize:12];
    self.dchange = TextButton(@"Đổi ảnh", 14, NO);
    [self.dchange addTarget:self action:@selector(onPickImage) forControlEvents:UIControlEventTouchUpInside];
    self.dopLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    self.dopLabel.text = @"Độ mờ";
    self.dopLabel.textColor = [UIColor whiteColor];
    self.dopLabel.font = [UIFont systemFontOfSize:12];
    self.dslider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    self.dslider.minimumValue = 0.2f;
    self.dslider.maximumValue = 1.0f;
    [self.dslider addTarget:self action:@selector(onDesignOpacity) forControlEvents:UIControlEventValueChanged];
    for (UIView *v in @[self.dminus, self.dzoom, self.dplus, self.dchange, self.dopLabel, self.dslider]) [self.dctl addSubview:v];
    [self.dpanel addSubview:self.dctl];
    self.dhandle = [[UIView alloc] initWithFrame:CGRectMake(204, 274, 26, 26)];
    UILabel *grip = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
    grip.text = @"◢";
    grip.textAlignment = NSTextAlignmentCenter;
    grip.textColor = [UIColor colorWithWhite:0.7f alpha:1];
    grip.font = [UIFont systemFontOfSize:14];
    [self.dhandle addSubview:grip];
    [self.dhandle addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPanDesignHandle:)]];
    [self.dpanel addSubview:self.dhandle];

    // ----- Thông báo cạnh nút nổi -----
    self.notifyView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 50)];
    self.notifyView.backgroundColor = [UIColor whiteColor];
    self.notifyView.layer.cornerRadius = 12;
    self.notifyView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.notifyView.layer.shadowOpacity = 0.4f;
    self.notifyView.layer.shadowRadius = 6;
    self.notifyView.layer.shadowOffset = CGSizeMake(0, 2);
    self.notifyView.hidden = YES;
    self.notifyTitle = [[UILabel alloc] initWithFrame:CGRectMake(11, 6, 178, 14)];
    self.notifyTitle.text = @"AIMOL";
    self.notifyTitle.font = [UIFont boldSystemFontOfSize:11];
    self.notifyTitle.textColor = [UIColor colorWithWhite:0.42f alpha:1];
    [self.notifyView addSubview:self.notifyTitle];
    self.notifyLabel = [[UILabel alloc] initWithFrame:CGRectMake(11, 20, 178, 22)];
    self.notifyLabel.font = [UIFont systemFontOfSize:12];
    self.notifyLabel.textColor = [UIColor colorWithWhite:0.07f alpha:1];
    self.notifyLabel.numberOfLines = 0;
    [self.notifyView addSubview:self.notifyLabel];
    [self.notifyView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onNoticeTap)]];

    // ----- Gắn vào cửa sổ, nạp trạng thái đã lưu, bố cục -----
    [w addSubview:self.panel];
    [w addSubview:self.dpanel];
    [w addSubview:self.notifyView];
    [w addSubview:self.floatBtn];
    [w addSubview:self.designBtn];
    [self loadUIState];
    self.designBtn.hidden = !self.designActive;
    [self applyPanelFrame];
    [self layoutDesign];
    [self reloadStorage];
    self.lastWinSize = w.bounds.size;
    [self bringOverlayToFront];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboard:)
                                                 name:UIKeyboardWillChangeFrameNotification object:nil];
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(tick)
                                                   userInfo:nil repeats:YES];

    [self log:@"Sẵn sàng. AIMOL đang ở chế độ chờ: không tự dump, không tự gọi AI."];
    if (issue) {
        NSString *m = [NSString stringWithFormat:@"⚠️ Phiên trước dừng đột ngột sau lệnh: %@. Bấm 📋 để xem nhật ký.", issue];
        [self log:m];
        [self showNotice:m seconds:10 force:NO];
    }
    if (dumpIssue) {
        [self log:[@"⚠️ " stringByAppendingString:dumpIssue]];
        if (!issue) [self showNotice:[@"⚠️ " stringByAppendingString:dumpIssue] seconds:10 force:NO];
    }
}

#pragma mark Kéo thả, mở/đóng, theo dõi cửa sổ

- (void)onPanPanel:(UIPanGestureRecognizer *)g {
    UIView *host = self.panel.superview;
    if (!host) return;
    CGPoint t = [g translationInView:host];
    CGRect f = self.panel.frame;
    self.panelOrigin = CGPointMake(f.origin.x + t.x, f.origin.y + t.y);
    self.hasPanelOrigin = YES;
    [g setTranslation:CGPointMake(0, 0) inView:host];
    [self applyPanelFrame];
    self.panelOrigin = self.panel.frame.origin;   // đồng bộ lại sau khi bị kẹp trong màn hình
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) [self saveUIState];
}

// Dùng chung cho nút AIMOL và cục tròn design
- (void)onPanBubble:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    if (!v.superview) return;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointMake(0, 0) inView:v.superview];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self clampBubble:v];
        [self saveUIState];
    }
}

- (void)setPanelOpen:(BOOL)open {
    self.panel.hidden = !open;
    if (open) {
        [self hideNotice];
        [self applyPanelFrame];
        [self bringOverlayToFront];
    } else {
        [self.panel endEditing:YES];
    }
}

- (void)onFloat { [self setPanelOpen:self.panel.hidden]; }

- (void)onTab {
    NSInteger i = self.tabSeg.selectedSegmentIndex;
    self.tabChat.hidden = (i != 0);
    self.table.hidden = (i != 1);
    self.tabTools.hidden = (i != 2);
    if (i == 1) [self reloadStorage];
    [self.panel endEditing:YES];
}

// Giữ overlay luôn ở trên cùng, theo kịp khi game đổi cửa sổ hoặc xoay màn hình
- (void)tick {
    UIWindow *w = [self keyWindow];
    if (!w || !self.installed) return;
    if (self.floatBtn.superview != w) {
        NSArray<UIView *> *vs = @[self.panel, self.dpanel, self.notifyView, self.floatBtn, self.designBtn];
        for (UIView *v in vs) { [v removeFromSuperview]; [w addSubview:v]; }
        if (self.previewBox) { [self.previewBox removeFromSuperview]; [w addSubview:self.previewBox]; }
        [self bringOverlayToFront];
    } else if (w.subviews.lastObject != self.designBtn) {
        [self bringOverlayToFront];
    }
    if (!CGSizeEqualToSize(w.bounds.size, self.lastWinSize)) {
        self.lastWinSize = w.bounds.size;
        [self clampBubble:self.floatBtn];
        [self clampBubble:self.designBtn];
        self.dFrame = [self clampDesignFrame:self.dFrame];
        [self applyPanelFrame];
        [self layoutDesign];
    }
}

- (void)onKeyboard:(NSNotification *)n {
    UIWindow *w = [self keyWindow];
    if (!w || !self.installed) return;
    CGRect kb = [(NSValue *)n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    kb = [w convertRect:kb fromView:nil];
    if (kb.origin.y >= w.bounds.size.height - 1) {
        self.keyboardUp = NO;
    } else {
        self.keyboardUp = YES;
        self.kbTop = kb.origin.y;
    }
    if (!self.panel.hidden) [self applyPanelFrame];
}

- (UIViewController *)topViewController {
    UIViewController *top = [self keyWindow].rootViewController;
    int guard = 0;
    while (top.presentedViewController && guard++ < 10) top = top.presentedViewController;
    return top;
}

#pragma mark Thông báo cạnh nút nổi

- (void)showNotice:(NSString *)text seconds:(NSTimeInterval)sec force:(BOOL)force {
    if (!self.installed || text.length == 0) return;
    if (!force && !self.panel.hidden) return;    // bảng đang mở thì người dùng đã thấy kết quả trong khung chat
    UIWindow *w = [self keyWindow];
    if (!w) return;
    self.notifyLabel.text = text;
    CGFloat maxW = MIN((CGFloat)230, w.bounds.size.width - 24);
    CGSize sz = [self.notifyLabel sizeThatFits:CGSizeMake(maxW - 22, CGFLOAT_MAX)];
    CGFloat nw = MIN(maxW, MAX((CGFloat)120, sz.width + 22));
    CGFloat nh = MIN((CGFloat)160, sz.height + 28);
    CGRect fr = self.floatBtn.frame;
    UIEdgeInsets in = w.safeAreaInsets;
    CGFloat x = fr.origin.x + fr.size.width / 2 - nw / 2;
    x = MIN(MAX(x, in.left + 6), MAX(in.left + 6, w.bounds.size.width - in.right - nw - 6));
    CGFloat y = fr.origin.y - nh - 10;
    if (y < in.top + 6) y = CGRectGetMaxY(fr) + 10;
    self.notifyView.frame = CGRectMake(x, y, nw, nh);
    self.notifyTitle.frame = CGRectMake(11, 6, nw - 22, 14);
    self.notifyLabel.frame = CGRectMake(11, 20, nw - 22, nh - 28);
    self.notifyView.hidden = NO;
    [self bringOverlayToFront];
    NSInteger token = ++self.notifyToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token == self.notifyToken) self.notifyView.hidden = YES;
    });
}

- (void)hideNotice {
    self.notifyToken++;
    self.notifyView.hidden = YES;
}

- (void)onNoticeTap { [self setPanelOpen:YES]; }

- (void)log:(NSString *)s {
    if (!s) return;
    NSString *old = self.chat.text ? self.chat.text : @"";
    NSString *merged = [old stringByAppendingFormat:@"%@\n\n", s];
    if (merged.length > 60000) merged = [merged substringFromIndex:merged.length - 50000];
    self.chat.text = merged;
    [self.chat scrollRangeToVisible:NSMakeRange(self.chat.text.length, 0)];
}

#pragma mark DUMP METADATA (chỉ khi bấm nút)

- (void)onDump {
    if (self.dumping) return;
    self.dumping = YES;
    self.dumpBtn.enabled = NO;
    [self.dumpBtn setTitle:@"Dumping..." forState:UIControlStateNormal];
    [self log:@"⏳ Dumping... (game có thể chậm vài giây)"];

    NSThread *t = [[NSThread alloc] initWithBlock:^{
        NSString *result = AIMOLDump(^(double p) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.dumping) {
                    [self.dumpBtn setTitle:[NSString stringWithFormat:@"Dumping %d%%", (int)(p * 100)]
                                  forState:UIControlStateNormal];
                }
            });
        });
        BOOL ok = gLastDumpOK;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.dumping = NO;
            self.dumpBtn.enabled = YES;
            [self log:result];
            [self showNotice:(ok ? @"✅ Dump Completed" : @"❌ Dump không thành công, mở bảng để xem lý do.") seconds:10 force:NO];
            if (ok) {
                [self.dumpBtn setTitle:@"Dump Completed" forState:UIControlStateNormal];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (!self.dumping) [self.dumpBtn setTitle:@"DUMP METADATA" forState:UIControlStateNormal];
                });
            } else {
                [self.dumpBtn setTitle:@"DUMP METADATA" forState:UIControlStateNormal];
            }
            [self onSearchChanged];
        });
    }];
    t.stackSize = 4 * 1024 * 1024;
    t.qualityOfService = NSQualityOfServiceUserInitiated;
    [t start];
}

- (void)onShare {
    NSString *path = nil;
    @synchronized (kCacheLockToken) { path = gDumpPath; }
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self log:@"Chưa có file dump. Hãy bấm DUMP METADATA trước."];
        return;
    }
    UIViewController *top = [self topViewController];
    if (!top) {
        [self log:[NSString stringWithFormat:@"Không mở được bảng chia sẻ. File nằm tại:\n%@", path]];
        return;
    }
    UIActivityViewController *avc = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = self.shareBtn;
    avc.popoverPresentationController.sourceRect = self.shareBtn.bounds;
    [top presentViewController:avc animated:YES completion:nil];
}

- (void)onLog {
    [self log:[@"📋 Nhật ký gần nhất:\n" stringByAppendingString:AimolLogTail(25)]];
}

#pragma mark Chat AI

- (NSString *)snapshotB64:(BOOL *)isBlack {
    *isBlack = NO;
    UIWindow *w = [self keyWindow];
    if (!w) return nil;
    NSArray<UIView *> *mine = @[self.panel, self.dpanel, self.notifyView, self.floatBtn, self.designBtn];
    NSMutableArray<NSNumber *> *was = [NSMutableArray array];
    for (UIView *v in mine) { [was addObject:@(v.hidden)]; v.hidden = YES; }   // không chụp chính overlay
    UIView *box = self.previewBox;
    BOOL boxWasHidden = box.hidden;
    box.hidden = YES;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:w.bounds.size format:fmt];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:YES];
    }];
    for (NSUInteger i = 0; i < mine.count; i++) mine[i].hidden = [was[i] boolValue];
    box.hidden = boxWasHidden;
    if (ImageLooksBlack(img)) { *isBlack = YES; return nil; }
    NSData *jpg = UIImageJPEGRepresentation(img, 0.6);
    return jpg ? [jpg base64EncodedStringWithOptions:0] : nil;
}

- (void)onSend {
    NSString *q = Trim(self.input.text ? self.input.text : @"");
    if (q.length == 0 || !self.sendBtn.enabled) return;
    NSInteger prov = self.provSeg.selectedSegmentIndex;
    NSString *rawKey = (prov == 0) ? self.geminiKey.text : self.claudeKey.text;
    NSString *key = Trim(rawKey ? rawKey : @"");
    if (key.length == 0) {
        [self log:@"Chưa nhập API Key cho nhà cung cấp đã chọn."];
        return;
    }
    self.input.text = @"";
    [self.input resignFirstResponder];
    [self log:[@"Bạn: " stringByAppendingString:q]];
    self.sendBtn.enabled = NO;

    BOOL black = NO;
    NSString *b64 = self.swImg.on ? [self snapshotB64:&black] : nil;
    NSString *prompt = q;
    if (black) prompt = [prompt stringByAppendingString:@"\n[Lưu ý: ảnh chụp màn hình bị đen, hãy dựa vào dữ liệu Dump.]"];
    if (self.swDump.on) prompt = [prompt stringByAppendingString:BuildDumpContext(q)];

    NSArray<NSDictionary *> *hist = [self.history copy];
    AskAI(prov, key, prompt, b64, hist, ^(NSString *reply, BOOL ok) {
        self.sendBtn.enabled = YES;
        [self log:[@"AI: " stringByAppendingString:reply]];
        if (ok) {
            [self.history addObject:@{@"q": q, @"a": reply}];
            while (self.history.count > kHistoryPairs) [self.history removeObjectAtIndex:0];
            [self harvestCode:reply];
        }
        [self showNotice:(ok ? @"AI vừa trả lời xong. Mở bảng để xem." : @"AI trả lời lỗi. Mở bảng để xem.") seconds:10 force:NO];
    });
}

// Tự lưu các khối code AI trả về vào Khu lưu trữ
- (void)harvestCode:(NSString *)reply {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"```([\\w-]*)[ \\t]*\\n([\\s\\S]*?)```"
                                                                        options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [re matchesInString:reply options:0 range:NSMakeRange(0, reply.length)];
    BOOL changed = NO;
    for (NSTextCheckingResult *m in matches) {
        NSString *lang = [[reply substringWithRange:[m rangeAtIndex:1]] lowercaseString];
        NSString *code = Trim([reply substringWithRange:[m rangeAtIndex:2]]);
        if (code.length == 0) continue;
        NSString *kind = @"text";
        if ([lang isEqualToString:@"json"] || [lang isEqualToString:@"aimol"]) {
            id j = [NSJSONSerialization JSONObjectWithData:[code dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([j isKindOfClass:[NSDictionary class]] || [j isKindOfClass:[NSArray class]]) kind = @"patch";
        } else if ([lang hasPrefix:@"js"] || [lang isEqualToString:@"javascript"]) {
            kind = @"js";
        } else if ([lang isEqualToString:@"html"]) {
            kind = @"html";
        }
        BOOL dup = NO;
        for (NSDictionary *p in self.patches) {
            if ([p[@"code"] isEqualToString:code]) { dup = YES; break; }
        }
        if (dup) continue;
        [self.patches insertObject:@{@"id": [[NSUUID UUID] UUIDString], @"kind": kind, @"code": code,
                                     @"title": TitleForCode(kind, code), @"ver": GameVersionTag()} atIndex:0];
        changed = YES;
    }
    while (self.patches.count > kMaxStoredItems) [self.patches removeLastObject];
    if (changed) {
        [[NSUserDefaults standardUserDefaults] setObject:self.patches forKey:kPatchStore];
        [self reloadStorage];
    }
}

#pragma mark Khu lưu trữ và kết quả tra cứu (hai bảng dùng chung delegate)

- (void)reloadStorage {
    NSString *cur = GameVersionTag();
    BOOL stale = NO;
    for (NSDictionary *p in self.patches) {
        id v = p[@"ver"];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0 && ![(NSString *)v isEqualToString:cur]) { stale = YES; break; }
    }
    if (stale) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 200, 52)];
        l.text = [NSString stringWithFormat:@"  ⚠️ Game hiện là %@. Mục lưu ở phiên bản khác có thể không còn đúng, hãy kiểm tra trước khi áp dụng.", cur];
        l.numberOfLines = 0;
        l.font = [UIFont systemFontOfSize:12];
        l.textColor = [UIColor colorWithRed:1.0f green:0.84f blue:0.04f alpha:1];
        l.backgroundColor = [UIColor colorWithRed:0.29f green:0.23f blue:0.0f alpha:1];
        self.table.tableHeaderView = l;
    } else {
        self.table.tableHeaderView = nil;
    }
    [self.table reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return tableView == self.table ? (NSInteger)self.patches.count : (NSInteger)self.searchResults.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return tableView == self.table ? 74 : 44;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL storage = (tableView == self.table);
    NSString *rid = storage ? @"aimolcell" : @"aimolres";
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    c.backgroundColor = [UIColor colorWithWhite:0.14f alpha:1];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray<UIView *> *old = [c.contentView.subviews copy];
    for (UIView *v in old) [v removeFromSuperview];
    CGFloat w = tableView.bounds.size.width;
    NSUInteger row = (NSUInteger)indexPath.row;

    if (storage) {
        if (row >= self.patches.count) return c;
        NSDictionary *p = self.patches[row];
        NSMutableAttributedString *as = [[NSMutableAttributedString alloc]
            initWithString:(p[@"title"] ? p[@"title"] : @"")
                attributes:@{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: [UIFont systemFontOfSize:13]}];
        NSString *ver = [p[@"ver"] isKindOfClass:[NSString class]] ? p[@"ver"] : @"";
        if (ver.length > 0) {
            [as appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:ver]
                attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.56f alpha:1], NSFontAttributeName: [UIFont systemFontOfSize:11]}]];
        }
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 4, w - 20, 26)];
        l.attributedText = as;
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        [c.contentView addSubview:l];

        CGFloat bw = MAX((CGFloat)40, (w - 20 - 12) / 3);
        NSArray<NSString *> *titles = @[@"Áp dụng ngay", @"Hoàn tác", @"Copy Code"];
        SEL sels[3] = {@selector(onApply:), @selector(onUndo:), @selector(onCopy:)};
        for (int i = 0; i < 3; i++) {
            UIButton *b = TextButton(titles[(NSUInteger)i], 14, NO);
            b.frame = CGRectMake(10 + (bw + 6) * i, 34, bw, 32);
            b.tag = indexPath.row;
            [b addTarget:self action:sels[i] forControlEvents:UIControlEventTouchUpInside];
            [c.contentView addSubview:b];
        }
    } else {
        if (row >= self.searchResults.count) return c;
        NSDictionary *r = self.searchResults[row];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(8, 2, MAX((CGFloat)40, w - 70), 40)];
        l.text = r[@"t"];
        l.font = [UIFont fontWithName:@"Menlo" size:10] ? [UIFont fontWithName:@"Menlo" size:10] : [UIFont systemFontOfSize:10];
        l.textColor = [UIColor whiteColor];
        l.numberOfLines = 2;
        [c.contentView addSubview:l];
        UIButton *b = TextButton(@"Copy", 13, NO);
        b.frame = CGRectMake(w - 60, 6, 52, 32);
        b.tag = indexPath.row;
        [b addTarget:self action:@selector(onCopyResult:) forControlEvents:UIControlEventTouchUpInside];
        [c.contentView addSubview:b];
    }
    return c;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return tableView == self.table; }

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView != self.table || style != UITableViewCellEditingStyleDelete) return;
    if ((NSUInteger)indexPath.row >= self.patches.count) return;
    [self.patches removeObjectAtIndex:(NSUInteger)indexPath.row];
    [[NSUserDefaults standardUserDefaults] setObject:self.patches forKey:kPatchStore];
    [self reloadStorage];
}

- (void)onCopy:(UIButton *)b {
    if ((NSUInteger)b.tag >= self.patches.count) return;
    [UIPasteboard generalPasteboard].string = self.patches[(NSUInteger)b.tag][@"code"];
    [self log:@"Đã copy code."];
}

- (void)onCopyResult:(UIButton *)b {
    if ((NSUInteger)b.tag >= self.searchResults.count) return;
    [UIPasteboard generalPasteboard].string = self.searchResults[(NSUInteger)b.tag][@"c"];
    [self log:@"Đã copy kết quả tra cứu."];
}

- (void)onUndo:(UIButton *)b {
    if ((NSUInteger)b.tag >= self.patches.count) return;
    NSString *itemId = self.patches[(NSUInteger)b.tag][@"id"];
    [self log:UndoItem(itemId)];
}

// Tìm WKWebView của GAME (bỏ qua các view của AIMOL)
- (WKWebView *)findWebView:(UIView *)root {
    if (!root || root == self.panel || root == self.previewBox || root == self.floatBtn ||
        root == self.designBtn || root == self.dpanel || root == self.notifyView) return nil;
    if ([root isKindOfClass:[WKWebView class]]) return (WKWebView *)root;
    for (UIView *s in root.subviews) {
        WKWebView *r = [self findWebView:s];
        if (r) return r;
    }
    return nil;
}

- (void)onApply:(UIButton *)b {
    if ((NSUInteger)b.tag >= self.patches.count) return;
    NSDictionary *p = self.patches[(NSUInteger)b.tag];
    NSString *kind = p[@"kind"];
    NSString *code = p[@"code"];
    NSString *itemId = p[@"id"];
    if ([kind isEqualToString:@"patch"]) {
        [self log:ApplyPatchJSON(code, itemId)];
    } else if ([kind isEqualToString:@"js"]) {
        WKWebView *wv = [self findWebView:[self keyWindow]];
        if (!wv) {
            [self log:@"Không tìm thấy WKWebView trong game (JS chỉ dùng cho game HTML5/GDevelop)."];
            return;
        }
        [wv evaluateJavaScript:code completionHandler:^(id result, NSError *error) {
            [self log:error ? [NSString stringWithFormat:@"❌ JS lỗi: %@", error.localizedDescription] : @"✅ JS đã chạy."];
        }];
    } else if ([kind isEqualToString:@"html"]) {
        [self showHTMLPreview:code];
    } else {
        [self log:@"Mục này không áp dụng trực tiếp được. Dùng Copy Code."];
    }
}

#pragma mark Tra cứu Dump

- (void)onSearchChanged {
    NSInteger token = ++self.searchToken;
    NSString *q = Trim(self.searchField.text ? self.searchField.text : @"");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self.searchToken) return;
        [self runSearch:q token:token];
    });
}

- (void)setResults:(NSArray<NSDictionary *> *)results hint:(NSString *)hint {
    self.searchResults = results ? results : @[];
    self.resultsHint.text = hint ? hint : @"";
    self.resultsHint.hidden = (hint.length == 0);
    [self.resultsTable reloadData];
}

- (void)runSearch:(NSString *)q token:(NSInteger)token {
    if (q.length < 2) { [self setResults:@[] hint:@"Gõ ít nhất 2 ký tự để tìm trong file Dump."]; return; }
    NSString *path = nil;
    @synchronized (kCacheLockToken) { path = gDumpPath; }
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self setResults:@[] hint:@"Chưa có Dump. Bấm DUMP METADATA trước."];
        return;
    }
    [self setResults:@[] hint:@"Đang tìm..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *res = SearchDumpFile(path, q, ^BOOL{ return token != self.searchToken; });
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self.searchToken) return;
            [self setResults:res hint:(res.count ? @"" : @"Không có kết quả.")];
        });
    });
}

#pragma mark Design (cục tròn riêng + bảng ảnh)

- (void)onDesignRow {
    if (self.designActive) {
        [self showNotice:@"Cục tròn design đã có sẵn." seconds:2 force:YES];
        return;
    }
    self.designActive = YES;
    self.designBtn.hidden = NO;
    CGPoint c = self.floatBtn.center;
    self.designBtn.center = CGPointMake(c.x - 70, c.y);
    [self clampBubble:self.designBtn];
    if (CGRectIntersectsRect(self.designBtn.frame, self.floatBtn.frame)) {
        self.designBtn.center = CGPointMake(c.x + 70, c.y);
        [self clampBubble:self.designBtn];
    }
    [self bringOverlayToFront];
    [self saveUIState];
    [self showNotice:@"Đã mở cục tròn design (nhấn giữ để tắt)." seconds:3 force:YES];
}

- (void)onDesignBubbleTap {
    self.designOpen = !self.designOpen;
    self.dpanel.hidden = !self.designOpen;
    if (self.designOpen) {
        self.dFrame = [self clampDesignFrame:self.dFrame];
        [self layoutDesign];
        [self bringOverlayToFront];
    }
}

- (void)onDesignLong:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    self.designActive = NO;
    self.designOpen = NO;
    self.designBtn.hidden = YES;
    self.dpanel.hidden = YES;
    [self saveUIState];
    [self showNotice:@"Đã tắt design." seconds:2 force:YES];
}

- (void)onDesignClose {
    self.designOpen = NO;
    self.dpanel.hidden = YES;
}

- (void)onPanDesignBar:(UIPanGestureRecognizer *)g {
    UIView *host = self.dpanel.superview;
    if (!host) return;
    CGPoint t = [g translationInView:host];
    CGRect f = self.dFrame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    self.dFrame = [self clampDesignFrame:f];
    self.hasDFrame = YES;
    [g setTranslation:CGPointMake(0, 0) inView:host];
    [self layoutDesign];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) [self saveUIState];
}

- (void)onPanDesignHandle:(UIPanGestureRecognizer *)g {
    UIView *host = self.dpanel.superview;
    if (!host) return;
    CGPoint t = [g translationInView:host];
    CGRect f = self.dFrame;
    f.size.width += t.x;
    f.size.height += t.y;
    self.dFrame = [self clampDesignFrame:f];
    self.hasDFrame = YES;
    [g setTranslation:CGPointMake(0, 0) inView:host];
    [self layoutDesign];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) [self saveUIState];
}

// Phóng to / thu nhỏ NGUYÊN BẢNG (không chỉ ảnh bên trong)
- (void)zoomDesign:(CGFloat)factor {
    CGRect f = self.dFrame;
    f.size.width *= factor;
    f.size.height *= factor;
    self.dFrame = [self clampDesignFrame:f];
    self.hasDFrame = YES;
    [self layoutDesign];
    [self saveUIState];
}

- (void)onDesignMinus { [self zoomDesign:(CGFloat)(1.0 / 1.2)]; }
- (void)onDesignPlus { [self zoomDesign:(CGFloat)1.2]; }

- (void)onDesignOpacity {
    self.dOpacity = self.dslider.value;
    [self layoutDesign];
    [self saveUIState];
}

- (void)onPickImage {
    UIViewController *top = [self topViewController];
    if (!top) {
        [self showNotice:@"Không mở được bộ chọn ảnh. Hãy copy ảnh rồi bấm Dán ảnh." seconds:6 force:YES];
        return;
    }
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.selectionLimit = 1;
    cfg.filter = [PHPickerFilter imagesFilter];
    PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    pk.delegate = self;
    [top presentViewController:pk animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *r = results.firstObject;
    if (!r) return;
    NSItemProvider *p = r.itemProvider;
    if (![p canLoadObjectOfClass:[UIImage class]]) {
        [self showNotice:@"Không đọc được ảnh đã chọn. Thử Dán ảnh." seconds:5 force:YES];
        return;
    }
    [p loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
        UIImage *img = [(NSObject *)obj isKindOfClass:[UIImage class]] ? (UIImage *)obj : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (img) [self setDesignImage:img save:YES];
            else [self showNotice:@"Không đọc được ảnh đã chọn. Thử Dán ảnh." seconds:5 force:YES];
        });
    }];
}

// Phương án phụ khi không mở được bộ chọn ảnh
- (void)onPasteImage {
    UIImage *img = [UIPasteboard generalPasteboard].image;
    if (!img) {
        [self showNotice:@"Bộ nhớ tạm chưa có ảnh. Hãy copy một ảnh rồi thử lại." seconds:5 force:YES];
        return;
    }
    [self setDesignImage:img save:YES];
}

- (UIImage *)downscaled:(UIImage *)img maxSide:(CGFloat)maxSide {
    CGSize s = img.size;
    CGFloat longest = MAX(s.width, s.height);
    if (longest <= 0 || longest <= maxSide) return img;
    CGFloat k = maxSide / longest;
    CGSize ns = CGSizeMake(floor(s.width * k), floor(s.height * k));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:ns format:fmt]
            imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
    }];
}

- (void)setDesignImage:(UIImage *)img save:(BOOL)save {
    UIImage *d = [self downscaled:img maxSide:1600];
    self.dimage.image = d;
    [self layoutDesign];
    if (save) {
        NSString *path = [self designImagePath];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *jpg = UIImageJPEGRepresentation(d, 0.85);
            if (jpg) [jpg writeToFile:path atomically:YES];
        });
    }
}

#pragma mark Xem trước / chạy giao diện HTML do AI tạo

- (void)closePreview {
    if (!self.previewBox) return;
    for (UIView *v in self.previewBox.subviews) {
        if ([v isKindOfClass:[WKWebView class]]) {
            [((WKWebView *)v).configuration.userContentController removeScriptMessageHandlerForName:@"aimol"];
        }
    }
    [self.previewBox removeFromSuperview];
    self.previewBox = nil;
}

- (void)showHTMLPreview:(NSString *)html {
    UIWindow *w = [self keyWindow];
    if (!w) return;
    [self closePreview];
    CGRect b = w.bounds;
    UIEdgeInsets in = w.safeAreaInsets;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(in.left + 8, in.top + 8,
                                                           b.size.width - in.left - in.right - 16,
                                                           b.size.height - in.top - in.bottom - 16)];
    box.backgroundColor = [UIColor colorWithWhite:0.05f alpha:0.98f];
    box.layer.cornerRadius = 12;
    box.clipsToBounds = YES;

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    [cfg.userContentController addScriptMessageHandler:self name:@"aimol"];
    WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectMake(0, 40, box.bounds.size.width, box.bounds.size.height - 40)
                                       configuration:cfg];
    [box addSubview:wv];

    UIButton *close = TextButton(@"Đóng ✕", 15, NO);
    close.frame = CGRectMake(box.bounds.size.width - 90, 4, 82, 32);
    [close addTarget:self action:@selector(closePreview) forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:close];

    [wv loadHTMLString:html baseURL:nil];
    self.previewBox = box;
    [w addSubview:box];
    [self bringOverlayToFront];
    [self log:@"Đã mở giao diện HTML. Trang có thể gửi patch qua window.webkit.messageHandlers.aimol."];
}

// HTML gọi window.webkit.messageHandlers.aimol.postMessage(JSON.stringify(patch))
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    id body = message.body;
    NSString *json = nil;
    if ([body isKindOfClass:[NSString class]]) {
        json = (NSString *)body;
    } else if ([NSJSONSerialization isValidJSONObject:body]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    }
    if (json.length == 0) return;
    NSString *res = ApplyPatchJSON(json, nil);
    [self log:[@"[HTML] " stringByAppendingString:res]];
    NSData *rd = [NSJSONSerialization dataWithJSONObject:@[res] options:0 error:nil];
    NSString *arr = rd ? [[NSString alloc] initWithData:rd encoding:NSUTF8StringEncoding] : @"[\"\"]";
    NSString *js = [NSString stringWithFormat:@"if(window.aimolResult){window.aimolResult(%@[0]);}", arr];
    [message.webView evaluateJavaScript:js completionHandler:nil];
}

@end

#pragma mark - Điểm vào

// Chỉ dựng giao diện (nút nổi). KHÔNG dump, KHÔNG gọi mạng.
__attribute__((constructor)) static void AIMOLEntry(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[AIMOLUI shared] install];
    });
}
