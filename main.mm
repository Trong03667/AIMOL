// AIMOLCore.dylib v2 - AI Modder Online (iOS arm64, Objective-C++)
//
// QUY TẮC CHO FILE .mm (đã từng gây lỗi biên dịch):
//   - `new`, `class`, `delete`, `this` là từ khóa C++ => KHÔNG viết Foo.new / Foo.class.
//     Luôn dùng [[Foo alloc] init] và [Foo class].
//   - Không dùng hằng CGPointZero (gây lỗi linker); dùng CGPointMake(0, 0).
//   - C++ không tự ép int -> enum; khi OR các enum phải ép kiểu tường minh.
//
// THIẾT KẾ:
//   - CHỈ dựng giao diện khi nạp. KHÔNG dump, KHÔNG gọi mạng cho đến khi người dùng bấm nút.
//   - Dump IL2CPP: chỉ chạy khi bấm [DUMP METADATA], trên luồng riêng, ghi thẳng ra file (không giữ cả bản dump trong RAM).
//   - Chỉ bắt buộc 11 hàm il2cpp_* cốt lõi; các hàm còn lại là tùy chọn (thiếu thì bỏ bớt thông tin, không lỗi).
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <WebKit/WebKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#if __has_include(<dobby.h>)
#import <dobby.h>
#define AIMOL_HAS_DOBBY 1
#endif

#pragma mark - Cấu hình (sửa tại đây nếu cần)

static NSString *const kGeminiModel    = @"gemini-2.5-flash";
static NSString *const kClaudeModel    = @"claude-sonnet-5-5";
static NSString *const kPatchStore     = @"aimol.patches";
static NSString *const kCacheLockToken = @"aimol.cache.lock";

static const NSUInteger kDumpContextBudget = 14000;  // số ký tự dữ liệu Dump tối đa gửi kèm mỗi câu hỏi
static const NSUInteger kCacheMaxClasses   = 3000;   // số class tối đa trong RAM Cache
static const NSUInteger kCacheTextLimit    = 3000;   // số ký tự tối đa lưu cho mỗi class trong Cache
static const NSUInteger kHistoryPairs      = 4;      // số lượt hỏi-đáp gần nhất gửi kèm làm ngữ cảnh
static const NSUInteger kMaxStoredItems    = 200;    // số mục tối đa trong Khu lưu trữ

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

#pragma mark - Dump metadata (CHỈ chạy khi người dùng bấm nút)

static NSMutableArray<NSDictionary *> *gCache = nil;   // RAM Cache: class chứa từ khóa quan trọng
static NSString *gDumpPath = nil;
static BOOL gLastDumpOK = NO;

static NSArray<NSString *> *DumpKeywords(void) {
    return @[@"Car", @"Vehicle", @"Physics", @"Wheel", @"Engine", @"Suspension", @"Speed"];
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

    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [dir stringByAppendingPathComponent:@"AIMOL_dump.cs"];
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

    NSMutableArray<NSDictionary *> *cache = [NSMutableArray array];
    NSArray<NSString *> *keywords = DumpKeywords();
    size_t done = 0, classCount = 0;

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
                void *k = il_image_get_class(img, j);
                done++;
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
                        if (score > 0 && (cache.count < kCacheMaxClasses || score == 5)) {
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

    @synchronized (kCacheLockToken) {
        gCache = cache;
        gDumpPath = path;
    }
    gLastDumpOK = YES;
    return [NSString stringWithFormat:@"✅ Dump Completed: %zu assembly, %zu class, %lu class khớp từ khóa (đã lưu RAM Cache).\nModule: %@\nFile đầy đủ: %@\n(Bấm nút chia sẻ ở thanh trên để lưu file ra ứng dụng Tệp.)",
            asmCount, classCount, (unsigned long)cache.count, mod.length ? mod : @"?", path];
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

static size_t TypeSize(NSString *t) {
    if ([t isEqualToString:@"float"] || [t isEqualToString:@"int"]) return 4;
    if ([t isEqualToString:@"double"] || [t isEqualToString:@"long"]) return 8;
    if ([t isEqualToString:@"bool"]) return 1;
    return 0;
}

static NSString *FormatValue(const uint8_t *b, size_t n, NSString *type) {
    if ([type isEqualToString:@"float"] && n == 4) { float v; memcpy(&v, b, 4); return [NSString stringWithFormat:@"%g", (double)v]; }
    if ([type isEqualToString:@"double"] && n == 8) { double v; memcpy(&v, b, 8); return [NSString stringWithFormat:@"%g", v]; }
    if ([type isEqualToString:@"int"] && n == 4) { int32_t v; memcpy(&v, b, 4); return [NSString stringWithFormat:@"%d", (int)v]; }
    if ([type isEqualToString:@"long"] && n == 8) { int64_t v; memcpy(&v, b, 8); return [NSString stringWithFormat:@"%lld", (long long)v]; }
    if ([type isEqualToString:@"bool"] && n == 1) return b[0] ? @"true" : @"false";
    NSMutableString *h = [NSMutableString string];
    for (size_t i = 0; i < n; i++) [h appendFormat:@"%02X", b[i]];
    return h;
}

// Tìm class theo tên đầy đủ "Namespace.Class" trong mọi assembly
static void *FindClass(NSString *full) {
    if (!LoadIl2cpp() || !il_class_from_name) return NULL;
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
static NSString *ResolveAddress(NSDictionary *d, uintptr_t *outAddr, NSString **outDesc) {
    id clsv = d[@"class"];
    NSArray *chain = [d[@"pointers"] isKindOfClass:[NSArray class]] ? (NSArray *)d[@"pointers"] : @[];

    if ([clsv isKindOfClass:[NSString class]] && [(NSString *)clsv length] > 0) {
        // ===== Chế độ theo đối tượng: static field (singleton) -> chuỗi pointer -> field =====
        NSString *cls = (NSString *)clsv;
        if (!LoadIl2cpp()) return gIl2cppError ? gIl2cppError : @"Không nạp được IL2CPP.";
        if (!il_class_from_name || !il_class_get_field_from_name || !il_field_static_get_value ||
            !il_field_get_flags || !il_field_get_offset) {
            return @"Game thiếu API IL2CPP cần cho patch theo đối tượng.";
        }
        void *klass = FindClass(cls);
        if (!klass) return [NSString stringWithFormat:@"Không tìm thấy class '%@' (kiểm tra lại tên trong Dump).", cls];

        id sfv = d[@"static_field"];
        if (![sfv isKindOfClass:[NSString class]] || [(NSString *)sfv length] == 0) {
            return @"Patch theo class cần 'static_field' (field static chứa đối tượng, ví dụ Instance).";
        }
        NSString *sfName = (NSString *)sfv;
        void *sf = il_class_get_field_from_name(klass, sfName.UTF8String);
        if (!sf) return [NSString stringWithFormat:@"Không có field '%@' trong class '%@'.", sfName, cls];
        if (!(il_field_get_flags(sf) & 0x10)) return [NSString stringWithFormat:@"Field '%@' không phải static.", sfName];

        uint64_t buf[8];
        memset(buf, 0, sizeof(buf));      // vùng đệm dư để field kiểu struct không làm tràn bộ nhớ
        il_field_static_get_value(sf, buf);
        uintptr_t addr = (uintptr_t)buf[0];
        if (addr < 0x10000) return [NSString stringWithFormat:@"Field static '%@' đang null: đối tượng chưa được tạo. Vào trận/chọn xe rồi thử lại.", sfName];

        for (id p in chain) {
            uintptr_t po = 0;
            if (![p isKindOfClass:[NSString class]] || !ParseHexStrict((NSString *)p, &po)) return @"'pointers' phải là mảng chuỗi hex, ví dụ [\"0x28\"].";
            uintptr_t next = 0;
            if (!MemRead(addr + po, &next, sizeof(next)) || next < 0x10000) return @"Chuỗi pointer lỗi: không đọc được đối tượng con.";
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
            void *ff = il_class_get_field_from_name(fk, fname.UTF8String);
            if (!ff) return [NSString stringWithFormat:@"Không có field '%@' (kiểm tra tên trong Dump).", fname];
            if (il_field_get_flags(ff) & 0x10) return [NSString stringWithFormat:@"Field '%@' là static; hãy dùng static_field.", fname];
            addr += il_field_get_offset(ff);
            fieldLabel = fname;
        } else {
            uintptr_t off = 0;
            if (!GetHex(d, @"offset", &off)) return @"Thiếu 'field' (tên) hoặc 'offset' (chuỗi hex) để chọn trường cần ghi.";
            addr += off;
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
    for (id p in chain) {
        uintptr_t po = 0;
        if (![p isKindOfClass:[NSString class]] || !ParseHexStrict((NSString *)p, &po)) return @"'pointers' phải là mảng chuỗi hex.";
        uintptr_t next = 0;
        if (!MemRead(addr, &next, sizeof(next)) || next < 0x10000) return @"Chuỗi pointer lỗi: không đọc được con trỏ.";
        addr = next + po;
    }
    *outAddr = addr;
    *outDesc = [NSString stringWithFormat:@"%@+0x%lX", mod.length ? mod : @"module", (unsigned long)off];
    return nil;
}

static NSString *ApplyOne(NSDictionary *d) {
    NSString *type = d[@"type"] ? [[d[@"type"] description] lowercaseString] : @"int";
    NSString *op = d[@"op"] ? [[d[@"op"] description] lowercaseString] : @"write";
    BOOL readOnly = [op isEqualToString:@"read"];

    uintptr_t addr = 0;
    NSString *desc = nil;
    NSString *err = ResolveAddress(d, &addr, &desc);
    if (err) return [@"❌ " stringByAppendingString:err];
    if (addr < 0x10000) return @"❌ Địa chỉ không hợp lệ.";

    uint8_t oldBuf[64], newBuf[64];
    memset(oldBuf, 0, sizeof(oldBuf));
    memset(newBuf, 0, sizeof(newBuf));
    size_t n = TypeSize(type);

    if ([type isEqualToString:@"bytes"]) {
        if (readOnly) {
            double len = 16;
            if (d[@"length"] && !ParseNumber(d[@"length"], &len)) return @"❌ 'length' không hợp lệ.";
            if (len < 1 || len > 64) return @"❌ 'length' phải từ 1 đến 64.";
            n = (size_t)len;
        } else {
            id vv = d[@"value"];
            if (![vv isKindOfClass:[NSString class]]) return @"❌ Kiểu bytes cần 'value' là chuỗi hex, ví dụ \"00 00 80 3F\".";
            NSString *hex = [[[(NSString *)vv stringByReplacingOccurrencesOfString:@" " withString:@""]
                              stringByReplacingOccurrencesOfString:@"0x" withString:@""] stringByReplacingOccurrencesOfString:@"0X" withString:@""];
            if (hex.length == 0 || (hex.length % 2) != 0 || hex.length > 128) return @"❌ Chuỗi hex phải có độ dài chẵn, tối đa 64 byte.";
            for (NSUInteger i = 0; i < hex.length; i += 2) {
                NSString *pair = [hex substringWithRange:NSMakeRange(i, 2)];
                char *end = NULL;
                unsigned long v = strtoul(pair.UTF8String, &end, 16);
                if (!end || *end != '\0') return @"❌ Chuỗi hex chứa ký tự không hợp lệ.";
                newBuf[i / 2] = (uint8_t)v;
            }
            n = hex.length / 2;
        }
    } else if (n == 0) {
        return [NSString stringWithFormat:@"❌ Kiểu '%@' không hỗ trợ (dùng float, double, int, long, bool, bytes).", type];
    } else if (!readOnly) {
        id vv = d[@"value"];
        if (vv == nil) return @"❌ Thiếu trường 'value'.";
        if ([type isEqualToString:@"bool"]) {
            BOOL bv = NO;
            if (!ParseBool(vv, &bv)) return @"❌ 'value' của kiểu bool phải là true/false.";
            newBuf[0] = bv ? 1 : 0;
        } else {
            double num = 0;
            if (!ParseNumber(vv, &num) || !std::isfinite(num)) return @"❌ 'value' phải là số hợp lệ.";
            if ([type isEqualToString:@"float"]) {
                float f = (float)num;
                if (!std::isfinite(f)) return @"❌ Giá trị float vượt phạm vi.";
                memcpy(newBuf, &f, 4);
            } else if ([type isEqualToString:@"double"]) {
                memcpy(newBuf, &num, 8);
            } else if ([type isEqualToString:@"int"]) {
                if (num < -2147483648.0 || num > 2147483647.0) return @"❌ Giá trị int vượt phạm vi 32 bit.";
                int32_t iv = (int32_t)std::llround(num);
                memcpy(newBuf, &iv, 4);
            } else {
                if (num < -9.2e18 || num > 9.2e18) return @"❌ Giá trị long vượt phạm vi.";
                int64_t lv = (int64_t)std::llround(num);
                memcpy(newBuf, &lv, 8);
            }
        }
    }

    if (!MemRead(addr, oldBuf, n)) return [NSString stringWithFormat:@"❌ Địa chỉ %p không đọc được, đã hủy (không ghi gì).", (void *)addr];
    NSString *oldStr = FormatValue(oldBuf, n, type);
    if (readOnly) return [NSString stringWithFormat:@"📖 %@ @%p = %@ (%@)", desc, (void *)addr, oldStr, type];

    if (!MemWrite(addr, newBuf, n)) return [NSString stringWithFormat:@"❌ Ghi thất bại tại %p (trang bộ nhớ bị khóa?). %@ vẫn = %@.", (void *)addr, desc, oldStr];
    uint8_t chk[64];
    memset(chk, 0, sizeof(chk));
    BOOL verified = MemRead(addr, chk, n) && memcmp(chk, newBuf, n) == 0;
    NSString *newStr = FormatValue(newBuf, n, type);
    if (verified) return [NSString stringWithFormat:@"✅ %@ @%p: %@ → %@ (%@, đã xác minh)", desc, (void *)addr, oldStr, newStr, type];
    return [NSString stringWithFormat:@"⚠️ %@ @%p: đã ghi %@ nhưng đọc lại không khớp (game có thể ghi đè lại giá trị).", desc, (void *)addr, newStr];
}

// Nhận một đối tượng JSON hoặc một mảng đối tượng
static NSString *ApplyPatchJSON(NSString *json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([obj isKindOfClass:[NSDictionary class]]) return ApplyOne((NSDictionary *)obj);
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSUInteger idx = 0;
        for (id item in (NSArray *)obj) {
            idx++;
            if ([item isKindOfClass:[NSDictionary class]]) {
                [lines addObject:[NSString stringWithFormat:@"#%lu %@", (unsigned long)idx, ApplyOne((NSDictionary *)item)]];
            } else {
                [lines addObject:[NSString stringWithFormat:@"#%lu ❌ Phần tử không phải đối tượng JSON.", (unsigned long)idx]];
            }
        }
        return lines.count ? [lines componentsJoinedByString:@"\n"] : @"❌ Mảng patch rỗng.";
    }
    return @"❌ JSON patch không hợp lệ.";
}

#pragma mark - AI (Gemini / Claude)

static NSString *AIMOLSystemRules(void) {
    return
    @"Bạn là AIMOL, trợ lý modding chạy ngay trong game trên iPhone. QUY TẮC BẮT BUỘC:\n"
    @"1) CHẾ ĐỘ CHỜ: chỉ trả lời khi người dùng bấm Gửi. Không tự khởi xướng hội thoại.\n"
    @"2) CHỈ NÓI VỀ GAME: game, vật lý 3D, thông số xe, bộ nhớ RAM, kết quả Dump và kỹ thuật modding. Câu hỏi ngoài chủ đề: từ chối ngắn gọn, lịch sự.\n"
    @"3) Mỗi câu trả lời gồm phần giải thích và toàn bộ số liệu/thông số vật lý chi tiết mà bạn đã tính.\n"
    @"4) Bạn nhận ảnh chụp màn hình game (nếu có) và [DUMP CACHE] gồm class, field (kiểu, offset), method (RVA). CHỈ dùng tên class/field/method có trong dữ liệu Dump. "
    @"Nếu thiếu dữ liệu, hãy nói rõ là thiếu và bảo người dùng bấm DUMP METADATA. Tuyệt đối không bịa tên hay offset.\n"
    @"5) Khi đề xuất patch RAM, đặt JSON trong khối ```json (một đối tượng hoặc một mảng). Có hai cách:\n"
    @"   A. Theo đối tượng (ưu tiên): {\"class\":\"Namespace.Class\",\"static_field\":\"Instance\",\"pointers\":[\"0x28\"],\"field\":\"tenField\",\"type\":\"float\",\"value\":1.5}\n"
    @"      - 'static_field' là field static (có trong Dump) chứa đối tượng singleton của class đó.\n"
    @"      - 'pointers' (tùy chọn) là danh sách offset của các field tham chiếu cần đi theo, lần lượt từ đối tượng đó.\n"
    @"      - 'field' là tên field cần ghi (offset tự tính); có thể thay bằng \"offset\":\"0x..\". 'field_class' (tùy chọn) nếu field thuộc class khác.\n"
    @"   B. Theo module (chỉ khi đã biết địa chỉ tính từ đầu module, ví dụ dữ liệu toàn cục): {\"module\":\"auto\",\"offset\":\"0x...\",\"pointers\":[],\"type\":\"float\",\"value\":1.0}\n"
    @"   type: float, double, int, long, bool hoặc bytes (value là chuỗi hex). Thêm \"op\":\"read\" để chỉ đọc giá trị hiện tại (nên đọc trước khi ghi).\n"
    @"   LƯU Ý: offset của field trong Dump là offset TRONG đối tượng, KHÔNG phải địa chỉ từ đầu module. Nếu không có static_field phù hợp, hãy nói rõ thay vì đoán.\n"
    @"6) Script JS đặt trong khối ```js (chỉ chạy được với game HTML5/WKWebView). Giao diện HTML đặt trong khối ```html; "
    @"trang HTML gọi window.webkit.messageHandlers.aimol.postMessage(JSON.stringify(patch)) để áp dụng patch và định nghĩa window.aimolResult=function(text){...} để nhận kết quả.\n"
    @"7) Ghi sai kiểu dữ liệu có thể làm văng game: hãy đề xuất giá trị vừa phải và nêu rủi ro nếu có.";
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
                 @"generationConfig": @{@"maxOutputTokens": @4096}};
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
            NSString *val = d[@"value"] ? [d[@"value"] description] : @"?";
            BOOL isRead = [[d[@"op"] description] isEqualToString:@"read"];
            NSString *target = cls ? [NSString stringWithFormat:@"%@.%@", cls, fld ? fld : (off ? off : @"?")] : (off ? off : @"?");
            title = isRead ? [NSString stringWithFormat:@"ĐỌC %@", target] : [NSString stringWithFormat:@"%@ = %@", target, val];
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

#pragma mark - Giao diện Overlay (UIKit)

@interface AIMOLUI : NSObject <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) UIButton *floatBtn;
@property (nonatomic, strong) UIButton *dumpBtn;
@property (nonatomic, strong) UIButton *shareBtn;
@property (nonatomic, strong) UIButton *sendBtn;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *tabChat;
@property (nonatomic, strong) UIView *previewBox;
@property (nonatomic, strong) UISegmentedControl *tabSeg;
@property (nonatomic, strong) UISegmentedControl *provSeg;
@property (nonatomic, strong) UITextField *geminiKey;
@property (nonatomic, strong) UITextField *claudeKey;
@property (nonatomic, strong) UITextField *input;
@property (nonatomic, strong) UITextView *chat;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *patches;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *history;
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic) CGSize lastWinSize;
@property (nonatomic) BOOL dumping;
@property (nonatomic) BOOL installed;
@property (nonatomic) BOOL keyboardUp;
+ (instancetype)shared;
- (void)install;
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
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]] &&
            sc.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return nil;
}

- (UITextField *)makeField:(NSString *)placeholder secure:(BOOL)secure defaultsKey:(NSString *)dkey {
    UITextField *t = [[UITextField alloc] initWithFrame:CGRectZero];
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

#pragma mark Dựng giao diện

- (CGRect)basePanelFrame {
    UIWindow *w = [self keyWindow];
    if (!w) return CGRectMake(10, 60, 340, 300);
    CGRect b = w.bounds;
    UIEdgeInsets in = w.safeAreaInsets;
    BOOL land = b.size.width > b.size.height;
    CGFloat availW = b.size.width - in.left - in.right - 16;
    CGFloat availH = b.size.height - in.top - in.bottom - 16;
    CGFloat pw = MIN(availW, land ? (CGFloat)520 : (CGFloat)420);
    CGFloat ph = land ? availH : MIN(availH, b.size.height * (CGFloat)0.55);
    CGFloat x = in.left + 8 + (availW - pw) / 2;
    CGFloat y = in.top + (land ? (CGFloat)8 : (CGFloat)60);
    return CGRectMake(x, y, pw, ph);
}

- (void)layoutPanel {
    CGFloat pw = self.panel.bounds.size.width;
    CGFloat ph = self.panel.bounds.size.height;
    self.titleLabel.frame = CGRectMake(12, 6, 70, 30);
    self.dumpBtn.frame = CGRectMake(pw - 148, 6, 138, 30);
    self.shareBtn.frame = CGRectMake(pw - 148 - 40, 6, 36, 30);
    self.tabSeg.frame = CGRectMake(10, 40, pw - 20, 30);
    CGFloat y0 = 76;
    CGFloat cw = pw - 20;
    CGFloat ch = MAX((CGFloat)120, ph - y0 - 8);
    self.tabChat.frame = CGRectMake(10, y0, cw, ch);
    self.table.frame = CGRectMake(10, y0, cw, ch);
    self.provSeg.frame = CGRectMake(0, 0, cw, 28);
    self.geminiKey.frame = CGRectMake(0, 32, cw / 2 - 2, 30);
    self.claudeKey.frame = CGRectMake(cw / 2 + 2, 32, cw / 2 - 2, 30);
    self.chat.frame = CGRectMake(0, 66, cw, MAX((CGFloat)40, ch - 66 - 38));
    self.input.frame = CGRectMake(0, ch - 34, cw - 64, 32);
    self.sendBtn.frame = CGRectMake(cw - 60, ch - 34, 60, 32);
}

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
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kPatchStore];
    self.patches = saved ? [saved mutableCopy] : [[NSMutableArray alloc] init];
    self.history = [[NSMutableArray alloc] init];

    // ----- Panel -----
    self.panel = [[UIView alloc] initWithFrame:[self basePanelFrame]];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    self.panel.layer.cornerRadius = 14;
    self.panel.clipsToBounds = YES;
    self.panel.hidden = YES;
    self.panel.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    // ----- Header Toolbar -----
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.text = @"AIMOL";
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.panel addSubview:self.titleLabel];

    self.dumpBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.dumpBtn setTitle:@"DUMP METADATA" forState:UIControlStateNormal];
    self.dumpBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [self.dumpBtn addTarget:self action:@selector(onDump) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.dumpBtn];

    self.shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.shareBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    [self.shareBtn addTarget:self action:@selector(onShare) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.shareBtn];

    self.tabSeg = [[UISegmentedControl alloc] initWithItems:@[@"CHAT AI", @"KHU LƯU TRỮ"]];
    self.tabSeg.selectedSegmentIndex = 0;
    [self.tabSeg addTarget:self action:@selector(onTab) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.tabSeg];

    // ----- TAB 1: CHAT AI -----
    self.tabChat = [[UIView alloc] initWithFrame:CGRectZero];
    self.provSeg = [[UISegmentedControl alloc] initWithItems:@[@"Gemini", @"Claude"]];
    self.provSeg.selectedSegmentIndex = 0;
    self.geminiKey = [self makeField:@"Gemini API Key" secure:YES defaultsKey:@"aimol.gemini"];
    self.claudeKey = [self makeField:@"Claude API Key" secure:YES defaultsKey:@"aimol.claude"];
    self.chat = [[UITextView alloc] initWithFrame:CGRectZero];
    self.chat.editable = NO;
    self.chat.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    self.chat.textColor = [UIColor whiteColor];
    self.chat.font = [UIFont systemFontOfSize:13];
    self.chat.layer.cornerRadius = 8;
    self.input = [self makeField:@"Nhập câu hỏi..." secure:NO defaultsKey:nil];
    self.input.returnKeyType = UIReturnKeySend;
    self.sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendBtn setTitle:@"Gửi" forState:UIControlStateNormal];
    [self.sendBtn addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    NSArray<UIView *> *chatViews = @[self.provSeg, self.geminiKey, self.claudeKey, self.chat, self.input, self.sendBtn];
    for (UIView *v in chatViews) [self.tabChat addSubview:v];
    [self.panel addSubview:self.tabChat];

    // ----- TAB 2: KHU LƯU TRỮ -----
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.backgroundColor = [UIColor clearColor];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 74;
    self.table.hidden = YES;
    [self.panel addSubview:self.table];

    [self layoutPanel];
    [w addSubview:self.panel];

    // ----- Nút nổi -----
    self.floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatBtn.frame = CGRectMake(w.bounds.size.width - 76, w.bounds.size.height * (CGFloat)0.35, 56, 56);
    self.floatBtn.backgroundColor = [UIColor blackColor];                            // #000000
    [self.floatBtn setTitle:@"AIMOL" forState:UIControlStateNormal];
    [self.floatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; // #FFFFFF
    self.floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    self.floatBtn.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.floatBtn.layer.cornerRadius = 28;
    self.floatBtn.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;
    self.floatBtn.layer.borderWidth = 1;
    [self.floatBtn addTarget:self action:@selector(onFloat) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.floatBtn addGestureRecognizer:pan];
    [w addSubview:self.floatBtn];

    self.lastWinSize = w.bounds.size;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboard:)
                                                 name:UIKeyboardWillChangeFrameNotification object:nil];
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(tick)
                                                   userInfo:nil repeats:YES];
    [self log:@"Sẵn sàng. AIMOL đang ở chế độ chờ: không tự dump, không tự gọi AI."];
}

// Giữ overlay luôn ở trên cùng, theo kịp khi game đổi cửa sổ hoặc xoay màn hình
- (void)tick {
    UIWindow *w = [self keyWindow];
    if (!w || !self.installed) return;
    if (self.floatBtn.superview != w) {
        [self.floatBtn removeFromSuperview];
        [self.panel removeFromSuperview];
        [w addSubview:self.panel];
        if (self.previewBox) [w addSubview:self.previewBox];
        [w addSubview:self.floatBtn];
    } else if (w.subviews.lastObject != self.floatBtn) {
        [w bringSubviewToFront:self.panel];
        if (self.previewBox) [w bringSubviewToFront:self.previewBox];
        [w bringSubviewToFront:self.floatBtn];
    }
    if (!CGSizeEqualToSize(w.bounds.size, self.lastWinSize)) {
        self.lastWinSize = w.bounds.size;
        if (!self.keyboardUp) {
            self.panel.frame = [self basePanelFrame];
            [self layoutPanel];
        }
        [self clampFloatButton];
    }
}

- (void)clampFloatButton {
    UIWindow *w = [self keyWindow];
    if (!w) return;
    UIEdgeInsets in = w.safeAreaInsets;
    CGFloat minX = in.left + 28, maxX = w.bounds.size.width - in.right - 28;
    CGFloat minY = in.top + 28, maxY = w.bounds.size.height - in.bottom - 28;
    CGPoint c = self.floatBtn.center;
    c.x = MIN(MAX(c.x, minX), MAX(minX, maxX));
    c.y = MIN(MAX(c.y, minY), MAX(minY, maxY));
    self.floatBtn.center = c;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointMake(0, 0) inView:v.superview];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self clampFloatButton];
    }
}

- (void)onFloat {
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) {
        [self.panel.superview bringSubviewToFront:self.panel];
        if (self.previewBox) [self.panel.superview bringSubviewToFront:self.previewBox];
        [self.panel.superview bringSubviewToFront:self.floatBtn];
    } else {
        [self.input resignFirstResponder];
        [self.geminiKey resignFirstResponder];
        [self.claudeKey resignFirstResponder];
    }
}

- (void)onTab {
    BOOL chatTab = (self.tabSeg.selectedSegmentIndex == 0);
    self.tabChat.hidden = !chatTab;
    self.table.hidden = chatTab;
    [self.table reloadData];
    [self.input resignFirstResponder];
}

- (void)onKeyboard:(NSNotification *)n {
    UIWindow *w = [self keyWindow];
    if (!w || self.panel.hidden || !self.installed) return;
    CGRect kb = [(NSValue *)n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    kb = [w convertRect:kb fromView:nil];
    CGRect base = [self basePanelFrame];
    if (kb.origin.y >= w.bounds.size.height - 1) {
        self.keyboardUp = NO;
        self.panel.frame = base;
    } else {
        self.keyboardUp = YES;
        CGFloat maxBottom = kb.origin.y - 6;
        CGFloat h = MAX((CGFloat)170, MIN(base.size.height, maxBottom - base.origin.y));
        CGRect f = base;
        f.size.height = h;
        if (CGRectGetMaxY(f) > maxBottom) f.origin.y = MAX(w.safeAreaInsets.top + 4, maxBottom - h);
        self.panel.frame = f;
    }
    [self layoutPanel];
}

- (void)log:(NSString *)s {
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
            if (ok) {
                [self.dumpBtn setTitle:@"Dump Completed" forState:UIControlStateNormal];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (!self.dumping) [self.dumpBtn setTitle:@"DUMP METADATA" forState:UIControlStateNormal];
                });
            } else {
                [self.dumpBtn setTitle:@"DUMP METADATA" forState:UIControlStateNormal];
            }
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
    UIWindow *w = [self keyWindow];
    UIViewController *top = w.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
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

#pragma mark Chat AI

- (NSString *)snapshotB64:(BOOL *)isBlack {
    *isBlack = NO;
    UIWindow *w = [self keyWindow];
    if (!w) return nil;
    BOOL panelWasHidden = self.panel.hidden;
    UIView *box = self.previewBox;
    BOOL boxWasHidden = box.hidden;
    self.panel.hidden = YES;
    self.floatBtn.hidden = YES;   // không chụp chính overlay
    box.hidden = YES;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:w.bounds.size format:fmt];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:YES];
    }];
    self.floatBtn.hidden = NO;
    self.panel.hidden = panelWasHidden;
    box.hidden = boxWasHidden;
    if (ImageLooksBlack(img)) { *isBlack = YES; return nil; }
    NSData *jpg = UIImageJPEGRepresentation(img, 0.6);
    return jpg ? [jpg base64EncodedStringWithOptions:0] : nil;
}

- (void)onSend {
    NSString *q = Trim(self.input.text ? self.input.text : @"");
    if (q.length == 0 || !self.sendBtn.enabled) return;
    NSInteger prov = self.provSeg.selectedSegmentIndex;
    NSString *key = Trim((prov == 0 ? self.geminiKey.text : self.claudeKey.text) ? (prov == 0 ? self.geminiKey.text : self.claudeKey.text) : @"");
    if (key.length == 0) {
        [self log:@"Chưa nhập API Key cho nhà cung cấp đã chọn."];
        return;
    }
    self.input.text = @"";
    [self.input resignFirstResponder];
    [self log:[@"Bạn: " stringByAppendingString:q]];
    self.sendBtn.enabled = NO;

    BOOL black = NO;
    NSString *b64 = [self snapshotB64:&black];
    NSString *prompt = q;
    if (black) prompt = [prompt stringByAppendingString:@"\n[Lưu ý: ảnh chụp màn hình bị đen, hãy dựa vào dữ liệu Dump.]"];
    prompt = [prompt stringByAppendingString:BuildDumpContext(q)];

    NSArray<NSDictionary *> *hist = [self.history copy];
    AskAI(prov, key, prompt, b64, hist, ^(NSString *reply, BOOL ok) {
        self.sendBtn.enabled = YES;
        [self log:[@"AI: " stringByAppendingString:reply]];
        if (ok) {
            [self.history addObject:@{@"q": q, @"a": reply}];
            while (self.history.count > kHistoryPairs) [self.history removeObjectAtIndex:0];
            [self harvestCode:reply];
        }
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
        [self.patches insertObject:@{@"kind": kind, @"code": code, @"title": TitleForCode(kind, code)} atIndex:0];
        changed = YES;
    }
    while (self.patches.count > kMaxStoredItems) [self.patches removeLastObject];
    if (changed) {
        [[NSUserDefaults standardUserDefaults] setObject:self.patches forKey:kPatchStore];
        [self.table reloadData];
    }
}

#pragma mark Khu lưu trữ (TAB 2)

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.patches.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"aimolcell"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"aimolcell"];
    c.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    NSArray<UIView *> *old = [c.contentView.subviews copy];
    for (UIView *v in old) [v removeFromSuperview];

    CGFloat w = tableView.bounds.size.width;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 4, w - 20, 26)];
    l.text = self.patches[(NSUInteger)indexPath.row][@"title"];
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:13];
    [c.contentView addSubview:l];

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.frame = CGRectMake(10, 34, w / 2 - 15, 32);
    apply.tag = indexPath.row;
    [apply setTitle:@"Áp dụng ngay" forState:UIControlStateNormal];
    [apply addTarget:self action:@selector(onApply:) forControlEvents:UIControlEventTouchUpInside];
    [c.contentView addSubview:apply];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    copy.frame = CGRectMake(w / 2 + 5, 34, w / 2 - 15, 32);
    copy.tag = indexPath.row;
    [copy setTitle:@"Copy Code" forState:UIControlStateNormal];
    [copy addTarget:self action:@selector(onCopy:) forControlEvents:UIControlEventTouchUpInside];
    [c.contentView addSubview:copy];
    return c;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    if ((NSUInteger)indexPath.row >= self.patches.count) return;
    [self.patches removeObjectAtIndex:(NSUInteger)indexPath.row];
    [[NSUserDefaults standardUserDefaults] setObject:self.patches forKey:kPatchStore];
    [tableView reloadData];
}

- (void)onCopy:(UIButton *)b {
    if ((NSUInteger)b.tag >= self.patches.count) return;
    [UIPasteboard generalPasteboard].string = self.patches[(NSUInteger)b.tag][@"code"];
    [self log:@"Đã copy code."];
}

// Tìm WKWebView của GAME (bỏ qua các view của AIMOL)
- (WKWebView *)findWebView:(UIView *)root {
    if (!root || root == self.panel || root == self.previewBox || root == self.floatBtn) return nil;
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
    if ([kind isEqualToString:@"patch"]) {
        [self log:ApplyPatchJSON(code)];
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
    box.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.98];
    box.layer.cornerRadius = 12;
    box.clipsToBounds = YES;

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    [cfg.userContentController addScriptMessageHandler:self name:@"aimol"];
    WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectMake(0, 40, box.bounds.size.width, box.bounds.size.height - 40)
                                       configuration:cfg];
    [box addSubview:wv];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(box.bounds.size.width - 90, 4, 82, 32);
    [close setTitle:@"Đóng ✕" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closePreview) forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:close];

    [wv loadHTMLString:html baseURL:nil];
    self.previewBox = box;
    [w addSubview:box];
    [w bringSubviewToFront:self.floatBtn];
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
    NSString *res = ApplyPatchJSON(json);
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
