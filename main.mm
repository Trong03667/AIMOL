// AIMOLCore - AI Modder Online (iOS ARM64 dylib)
// Overlay UIKit + Dump IL2CPP thu cong + Memory tool + Gemini/Claude (Vision)
//
// LUU Y ObjC++: `new`, `class`, `delete`, `this`... la tu khoa C++.
// KHONG dung dot-syntax nhu `Foo.new` hoac `Foo.class` trong file .mm,
// luon dung [[Foo alloc] init] va [Foo class].
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>

#if __has_include(<dobby.h>)
#import <dobby.h>
#define AIMOL_HAS_DOBBY 1
#endif

#pragma mark - IL2CPP bindings (nap dong qua dlsym)

static void*       (*il_domain_get)(void);
static void**      (*il_domain_get_assemblies)(void *, size_t *);
static void*       (*il_assembly_get_image)(void *);
static size_t      (*il_image_get_class_count)(void *);
static void*       (*il_image_get_class)(void *, size_t);
static const char* (*il_class_get_name)(void *);
static const char* (*il_class_get_namespace)(void *);
static void*       (*il_class_get_fields)(void *, void **);
static void*       (*il_class_get_methods)(void *, void **);
static const char* (*il_field_get_name)(void *);
static size_t      (*il_field_get_offset)(void *);
static const char* (*il_method_get_name)(void *);
static uint32_t    (*il_method_get_param_count)(void *);
static void*       (*il_thread_attach)(void *);

static BOOL LoadIl2cpp(void) {
    if (il_domain_get) return YES;
    NSString *p = [[NSBundle mainBundle].privateFrameworksPath
                   stringByAppendingString:@"/UnityFramework.framework/UnityFramework"];
    void *h = dlopen(p.UTF8String, RTLD_NOW | RTLD_NOLOAD);
    if (!h) h = dlopen(p.UTF8String, RTLD_NOW);
    if (!h) h = RTLD_DEFAULT;
#define AIMOL_LOAD(n) il_##n = (decltype(il_##n))dlsym(h, "il2cpp_" #n)
    AIMOL_LOAD(domain_get);
    AIMOL_LOAD(domain_get_assemblies);
    AIMOL_LOAD(assembly_get_image);
    AIMOL_LOAD(image_get_class_count);
    AIMOL_LOAD(image_get_class);
    AIMOL_LOAD(class_get_name);
    AIMOL_LOAD(class_get_namespace);
    AIMOL_LOAD(class_get_fields);
    AIMOL_LOAD(class_get_methods);
    AIMOL_LOAD(field_get_name);
    AIMOL_LOAD(field_get_offset);
    AIMOL_LOAD(method_get_name);
    AIMOL_LOAD(method_get_param_count);
    AIMOL_LOAD(thread_attach);
#undef AIMOL_LOAD
    return il_domain_get && il_domain_get_assemblies && il_assembly_get_image &&
           il_image_get_class_count && il_image_get_class && il_class_get_name &&
           il_class_get_fields && il_class_get_methods && il_field_get_name &&
           il_field_get_offset && il_method_get_name && il_thread_attach;
}

#pragma mark - Dump metadata (CHI chay khi nguoi dung bam nut)

static NSMutableArray<NSString *> *gCache;   // RAM cache: class chua tu khoa quan trong
static NSString *gDumpPath;

static NSString *AIMOLDump(void) {
    if (!LoadIl2cpp()) {
        return @"Khong tim thay IL2CPP API (game khong phai Unity IL2CPP hoac symbol bi strip).";
    }
    void *dom = il_domain_get();
    if (!dom) return @"il2cpp_domain_get tra ve NULL (game chua khoi tao xong IL2CPP).";
    il_thread_attach(dom);   // thread nen phai attach truoc khi goi API

    NSArray *keywords = @[@"car", @"vehicle", @"physics", @"wheel", @"engine", @"suspension", @"speed"];
    NSMutableString *full = [[NSMutableString alloc] init];
    NSMutableArray<NSString *> *cache = [[NSMutableArray alloc] init];
    size_t asmCount = 0, classTotal = 0;
    void **asms = il_domain_get_assemblies(dom, &asmCount);

    for (size_t i = 0; i < asmCount; i++) {
        void *img = il_assembly_get_image(asms[i]);
        if (!img) continue;
        size_t cc = il_image_get_class_count(img);
        for (size_t j = 0; j < cc; j++) {
            void *k = il_image_get_class(img, j);
            if (!k) continue;
            classTotal++;
            const char *ns = il_class_get_namespace ? il_class_get_namespace(k) : "";
            const char *nm = il_class_get_name(k);
            NSMutableString *b = [NSMutableString stringWithFormat:@"class %s%s%s\n",
                                  (ns && *ns) ? ns : "", (ns && *ns) ? "." : "", nm ? nm : "?"];
            void *it = NULL;
            void *fld = NULL;
            while ((fld = il_class_get_fields(k, &it))) {
                const char *fn = il_field_get_name(fld);
                [b appendFormat:@"  field %s // offset 0x%zX\n", fn ? fn : "?", il_field_get_offset(fld)];
            }
            it = NULL;
            void *mth = NULL;
            while ((mth = il_class_get_methods(k, &it))) {
                void *ptr = *(void **)mth;   // MethodInfo->methodPointer o offset 0
                Dl_info di;
                uintptr_t rva = 0;
                if (ptr && dladdr(ptr, &di)) rva = (uintptr_t)ptr - (uintptr_t)di.dli_fbase;
                const char *mn = il_method_get_name(mth);
                uint32_t pc = il_method_get_param_count ? il_method_get_param_count(mth) : 0;
                [b appendFormat:@"  method %s(%u) // ptr=%p RVA=0x%lX\n", mn ? mn : "?", pc, ptr, (unsigned long)rva];
            }
            [full appendString:b];
            NSString *low = b.lowercaseString;
            for (NSString *w in keywords) {
                if ([low containsString:w]) { [cache addObject:b]; break; }
            }
        }
    }
    gCache = cache;
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    gDumpPath = [dir stringByAppendingPathComponent:@"AIMOL_dump.txt"];
    [full writeToFile:gDumpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return [NSString stringWithFormat:@"Dump xong: %zu assembly, %zu class, %lu class khop tu khoa (cache RAM).\nFile day du: %@",
            asmCount, classTotal, (unsigned long)cache.count, gDumpPath];
}

#pragma mark - Memory tool

static uintptr_t ModuleBase(NSString *name) {
    if (name.length == 0) name = @"UnityFramework";
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, name.UTF8String)) return (uintptr_t)_dyld_get_image_header(i);
    }
    return (uintptr_t)_dyld_get_image_header(0);
}

static BOOL MemRead(uintptr_t a, void *out, size_t n) {
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)a, (vm_size_t)n,
                                         (vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == n;
}

static BOOL MemWrite(uintptr_t a, const void *src, size_t n) {
    vm_protect(mach_task_self(), (vm_address_t)a, (vm_size_t)n, 0,
               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    kern_return_t kr = vm_write(mach_task_self(), (vm_address_t)a, (vm_offset_t)src,
                                (mach_msg_type_number_t)n);
    return kr == KERN_SUCCESS;
}

static uintptr_t ParseHex(NSString *s) { return (uintptr_t)strtoull(s.UTF8String, NULL, 16); }

// Patch JSON: {"module":"UnityFramework","offset":"0x1234","pointers":["0x10"],
//              "type":"float|int|bool|bytes","value":123.0}
static NSString *ApplyPatchJSON(NSString *json) {
    id obj = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                             options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return @"JSON patch khong hop le.";
    NSDictionary *d = (NSDictionary *)obj;
    if (!d[@"offset"]) return @"JSON patch thieu truong offset.";

    uintptr_t addr = ModuleBase(d[@"module"]) + ParseHex([d[@"offset"] description]);
    NSArray *chain = [d[@"pointers"] isKindOfClass:[NSArray class]] ? d[@"pointers"] : @[];
    for (id p in chain) {
        uintptr_t next = 0;
        if (!MemRead(addr, &next, sizeof(next)) || next == 0) return @"Chuoi pointer loi (dia chi khong doc duoc).";
        addr = next + ParseHex([p description]);
    }

    NSString *type = d[@"type"] ? [d[@"type"] description] : @"int";
    BOOL ok = NO;
    if ([type isEqualToString:@"float"]) {
        float v = [d[@"value"] floatValue];
        ok = MemWrite(addr, &v, sizeof(v));
    } else if ([type isEqualToString:@"int"]) {
        int32_t v = (int32_t)[d[@"value"] intValue];
        ok = MemWrite(addr, &v, sizeof(v));
    } else if ([type isEqualToString:@"bool"]) {
        uint8_t v = [d[@"value"] boolValue] ? 1 : 0;
        ok = MemWrite(addr, &v, sizeof(v));
    } else if ([type isEqualToString:@"bytes"]) {
        NSString *hex = [[d[@"value"] description] stringByReplacingOccurrencesOfString:@" " withString:@""];
        NSMutableData *buf = [[NSMutableData alloc] init];
        for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
            uint8_t byte = (uint8_t)strtoul([hex substringWithRange:NSMakeRange(i, 2)].UTF8String, NULL, 16);
            [buf appendBytes:&byte length:1];
        }
        ok = (buf.length > 0) && MemWrite(addr, buf.bytes, buf.length);
    } else {
        return [NSString stringWithFormat:@"Kieu '%@' khong ho tro.", type];
    }
    if (ok) return [NSString stringWithFormat:@"Da ghi (%@) tai %p.", type, (void *)addr];
    return [NSString stringWithFormat:@"Ghi that bai tai %p (trang bo nho bi khoa?).", (void *)addr];
}

#ifdef AIMOL_HAS_DOBBY
// Hook qua Dobby (chi bat khi co dobby.h + libdobby luc build)
extern "C" int AIMOLHook(void *target, void *replace, void **orig) {
    return DobbyHook(target, replace, orig);
}
#endif

#pragma mark - AI (Gemini / Claude)

static NSString *const kSystemRules =
    @"Ban la AIMOL, tro ly modding trong game tren iOS. Chi tra loi ve game, vat ly 3D, thong so xe, "
    @"bo nho RAM, ket qua Dump va ky thuat modding. Neu cau hoi ngoai chu de game, hay tu choi ngan gon. "
    @"Khong tu khoi xuong hoi thoai. Tra loi gom giai thich + so lieu/thong so vat ly chi tiet. "
    @"Khi de xuat patch RAM, dua JSON trong khoi ```json voi dang "
    @"{\"module\":\"UnityFramework\",\"offset\":\"0x...\",\"pointers\":[],\"type\":\"float\",\"value\":1.0}. "
    @"Script JS dat trong ```js, giao dien HTML dat trong ```html. "
    @"Chi dung offset co trong du lieu Dump duoc cung cap.";

static void AskAI(NSInteger provider, NSString *key, NSString *prompt, NSString *b64,
                  void (^done)(NSString *)) {
    NSString *ctx = @"";
    if (gCache.count > 0) {
        NSUInteger n = MIN((NSUInteger)40, gCache.count);
        NSString *joined = [[gCache subarrayWithRange:NSMakeRange(0, n)] componentsJoinedByString:@"\n"];
        if (joined.length > 6000) joined = [joined substringToIndex:6000];
        ctx = [NSString stringWithFormat:@"\n\n[DUMP CACHE]\n%@", joined];
    }
    NSString *text = [prompt stringByAppendingString:ctx];

    NSMutableURLRequest *req = nil;
    NSDictionary *body = nil;
    if (provider == 0) {
        NSString *url = [NSString stringWithFormat:
            @"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=%@", key];
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        NSMutableArray *parts = [NSMutableArray arrayWithObject:@{@"text": text}];
        if (b64) [parts addObject:@{@"inline_data": @{@"mime_type": @"image/jpeg", @"data": b64}}];
        body = @{@"system_instruction": @{@"parts": @[@{@"text": kSystemRules}]},
                 @"contents": @[@{@"role": @"user", @"parts": parts}]};
    } else {
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.anthropic.com/v1/messages"]];
        [req setValue:key forHTTPHeaderField:@"x-api-key"];
        [req setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
        NSMutableArray *content = [[NSMutableArray alloc] init];
        if (b64) {
            [content addObject:@{@"type": @"image",
                                 @"source": @{@"type": @"base64", @"media_type": @"image/jpeg", @"data": b64}}];
        }
        [content addObject:@{@"type": @"text", @"text": text}];
        body = @{@"model": @"claude-sonnet-5-5", @"max_tokens": @2048, @"system": kSystemRules,
                 @"messages": @[@{@"role": @"user", @"content": content}]};
    }
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 90;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSString *out = nil;
            if (err) {
                out = [@"Loi mang: " stringByAppendingString:err.localizedDescription];
            } else {
                id j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                NSString *t = nil;
                @try {
                    if (provider == 0) t = j[@"candidates"][0][@"content"][@"parts"][0][@"text"];
                    else               t = j[@"content"][0][@"text"];
                } @catch (NSException *ex) { t = nil; }
                if (t) out = t;
                else {
                    NSString *raw = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                    out = [NSString stringWithFormat:@"API tra loi loi: %@", raw];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ done(out); });
        }];
    [task resume];
}

#pragma mark - Overlay UI

static NSString *const kPatchStore = @"aimol.patches";

@interface AIMOLUI : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIButton *floatBtn;
@property (nonatomic, strong) UIButton *dumpBtn;
@property (nonatomic, strong) UIButton *sendBtn;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *tabChat;
@property (nonatomic, strong) UISegmentedControl *tabSeg;
@property (nonatomic, strong) UISegmentedControl *provSeg;
@property (nonatomic, strong) UITextField *geminiKey;
@property (nonatomic, strong) UITextField *claudeKey;
@property (nonatomic, strong) UITextField *input;
@property (nonatomic, strong) UITextView *chat;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *patches;
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

- (UITextField *)makeField:(NSString *)placeholder frame:(CGRect)frame secure:(BOOL)secure defaultsKey:(NSString *)dkey {
    UITextField *t = [[UITextField alloc] initWithFrame:frame];
    t.placeholder = placeholder;
    t.secureTextEntry = secure;
    t.borderStyle = UITextBorderStyleRoundedRect;
    t.font = [UIFont systemFontOfSize:13];
    t.autocapitalizationType = UITextAutocapitalizationTypeNone;
    t.autocorrectionType = UITextAutocorrectionTypeNo;
    if (dkey) {
        t.text = [[NSUserDefaults standardUserDefaults] stringForKey:dkey];
        [t addTarget:self action:@selector(saveKeys) forControlEvents:UIControlEventEditingChanged];
    }
    return t;
}

- (void)saveKeys {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:(self.geminiKey.text ?: @"") forKey:@"aimol.gemini"];
    [ud setObject:(self.claudeKey.text ?: @"") forKey:@"aimol.claude"];
}

- (void)install {
    UIWindow *w = [self keyWindow];
    if (!w) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self install];
        });
        return;
    }
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kPatchStore];
    self.patches = saved ? [saved mutableCopy] : [[NSMutableArray alloc] init];

    CGFloat pw = MIN(w.bounds.size.width - 20, 420);
    CGFloat ph = w.bounds.size.height * 0.48;
    self.panel = [[UIView alloc] initWithFrame:CGRectMake((w.bounds.size.width - pw) / 2,
                                                          w.safeAreaInsets.top + 70, pw, ph)];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    self.panel.layer.cornerRadius = 14;
    self.panel.clipsToBounds = YES;
    self.panel.hidden = YES;
    self.panel.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, 80, 32)];
    title.text = @"AIMOL";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:17];
    [self.panel addSubview:title];

    self.dumpBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.dumpBtn.frame = CGRectMake(pw - 150, 6, 140, 32);
    [self.dumpBtn setTitle:@"DUMP METADATA" forState:UIControlStateNormal];
    self.dumpBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [self.dumpBtn addTarget:self action:@selector(onDump) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.dumpBtn];

    self.tabSeg = [[UISegmentedControl alloc] initWithItems:@[@"CHAT AI", @"KHU LUU TRU"]];
    self.tabSeg.frame = CGRectMake(10, 42, pw - 20, 30);
    self.tabSeg.selectedSegmentIndex = 0;
    [self.tabSeg addTarget:self action:@selector(onTab) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.tabSeg];

    CGFloat y0 = 78;
    CGFloat cw = pw - 20;
    CGFloat ch = ph - y0 - 6;

    // TAB 1: CHAT AI
    self.tabChat = [[UIView alloc] initWithFrame:CGRectMake(10, y0, cw, ch)];
    self.provSeg = [[UISegmentedControl alloc] initWithItems:@[@"Gemini", @"Claude"]];
    self.provSeg.frame = CGRectMake(0, 0, cw, 28);
    self.provSeg.selectedSegmentIndex = 0;
    self.geminiKey = [self makeField:@"Gemini API Key" frame:CGRectMake(0, 32, cw / 2 - 2, 30)
                              secure:YES defaultsKey:@"aimol.gemini"];
    self.claudeKey = [self makeField:@"Claude API Key" frame:CGRectMake(cw / 2 + 2, 32, cw / 2 - 2, 30)
                              secure:YES defaultsKey:@"aimol.claude"];
    self.chat = [[UITextView alloc] initWithFrame:CGRectMake(0, 66, cw, ch - 66 - 38)];
    self.chat.editable = NO;
    self.chat.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    self.chat.textColor = [UIColor whiteColor];
    self.chat.font = [UIFont systemFontOfSize:13];
    self.chat.layer.cornerRadius = 8;
    self.input = [self makeField:@"Nhap cau hoi..." frame:CGRectMake(0, ch - 34, cw - 64, 32)
                          secure:NO defaultsKey:nil];
    self.sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendBtn.frame = CGRectMake(cw - 60, ch - 34, 60, 32);
    [self.sendBtn setTitle:@"Gui" forState:UIControlStateNormal];
    [self.sendBtn addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    NSArray<UIView *> *chatViews = @[self.provSeg, self.geminiKey, self.claudeKey, self.chat, self.input, self.sendBtn];
    for (UIView *v in chatViews) [self.tabChat addSubview:v];
    [self.panel addSubview:self.tabChat];

    // TAB 2: KHU LUU TRU
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(10, y0, cw, ch) style:UITableViewStylePlain];
    self.table.backgroundColor = [UIColor clearColor];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 74;
    self.table.hidden = YES;
    [self.panel addSubview:self.table];
    [w addSubview:self.panel];

    // Nut noi
    self.floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatBtn.frame = CGRectMake(w.bounds.size.width - 76, w.bounds.size.height * 0.35, 56, 56);
    self.floatBtn.backgroundColor = [UIColor blackColor];                       // #000000
    [self.floatBtn setTitle:@"AIMOL" forState:UIControlStateNormal];
    [self.floatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];  // #FFFFFF
    self.floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    self.floatBtn.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.floatBtn.layer.cornerRadius = 28;
    self.floatBtn.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;
    self.floatBtn.layer.borderWidth = 1;
    [self.floatBtn addTarget:self action:@selector(onFloat) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.floatBtn addGestureRecognizer:pan];
    [w addSubview:self.floatBtn];

    [self log:@"San sang. AIMOL dang o che do cho (Standby)."];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

- (void)onFloat {
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) {
        [self.panel.superview bringSubviewToFront:self.panel];
        [self.panel.superview bringSubviewToFront:self.floatBtn];
    }
}

- (void)onTab {
    BOOL chatTab = (self.tabSeg.selectedSegmentIndex == 0);
    self.tabChat.hidden = !chatTab;
    self.table.hidden = chatTab;
    [self.table reloadData];
    [self.input resignFirstResponder];
}

- (void)log:(NSString *)s {
    NSString *old = self.chat.text ? self.chat.text : @"";
    self.chat.text = [old stringByAppendingFormat:@"%@\n\n", s];
    [self.chat scrollRangeToVisible:NSMakeRange(self.chat.text.length, 0)];
}

- (void)onDump {
    [self.dumpBtn setTitle:@"Dang dump..." forState:UIControlStateNormal];
    self.dumpBtn.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = AIMOLDump();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self log:result];
            [self.dumpBtn setTitle:@"DUMP METADATA" forState:UIControlStateNormal];
            self.dumpBtn.enabled = YES;
        });
    });
}

- (NSString *)snapshotB64 {
    UIWindow *w = [self keyWindow];
    if (!w) return nil;
    self.panel.hidden = YES;
    self.floatBtn.hidden = YES;   // khong chup chinh overlay
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:w.bounds.size format:fmt];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:YES];
    }];
    self.floatBtn.hidden = NO;
    self.panel.hidden = NO;
    NSData *jpg = UIImageJPEGRepresentation(img, 0.5);
    return jpg ? [jpg base64EncodedStringWithOptions:0] : nil;
}

- (void)onSend {
    NSString *q = [self.input.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (q.length == 0) return;
    NSInteger prov = self.provSeg.selectedSegmentIndex;
    NSString *key = (prov == 0) ? self.geminiKey.text : self.claudeKey.text;
    if (key.length == 0) {
        [self log:@"Chua nhap API Key cho nha cung cap da chon."];
        return;
    }
    self.input.text = @"";
    [self.input resignFirstResponder];
    [self log:[@"Ban: " stringByAppendingString:q]];
    self.sendBtn.enabled = NO;
    NSString *b64 = [self snapshotB64];
    AskAI(prov, key, q, b64, ^(NSString *reply) {
        self.sendBtn.enabled = YES;
        [self log:[@"AI: " stringByAppendingString:reply]];
        [self harvestCode:reply];
    });
}

// Tu luu cac khoi code AI tra ve vao Khu luu tru
- (void)harvestCode:(NSString *)reply {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"```(\\w*)\\n([\\s\\S]*?)```"
                                                                        options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [re matchesInString:reply options:0 range:NSMakeRange(0, reply.length)];
    for (NSTextCheckingResult *m in matches) {
        NSString *lang = [[reply substringWithRange:[m rangeAtIndex:1]] lowercaseString];
        NSString *code = [reply substringWithRange:[m rangeAtIndex:2]];
        NSString *kind = @"text";
        if ([lang isEqualToString:@"json"] || [lang isEqualToString:@"aimol"]) kind = @"patch";
        else if ([lang hasPrefix:@"js"] || [lang isEqualToString:@"javascript"]) kind = @"js";
        else if ([lang isEqualToString:@"html"]) kind = @"html";
        NSString *firstLine = [[code componentsSeparatedByString:@"\n"] firstObject];
        if (!firstLine) firstLine = @"";
        if (firstLine.length > 40) firstLine = [firstLine substringToIndex:40];
        NSString *title = [NSString stringWithFormat:@"[%@] %@", [kind uppercaseString], firstLine];
        [self.patches insertObject:@{@"kind": kind, @"code": code, @"title": title} atIndex:0];
    }
    [[NSUserDefaults standardUserDefaults] setObject:self.patches forKey:kPatchStore];
    [self.table reloadData];
}

#pragma mark UITableView (TAB 2)

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
    [apply setTitle:@"Ap dung ngay" forState:UIControlStateNormal];
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

- (void)onCopy:(UIButton *)b {
    [UIPasteboard generalPasteboard].string = self.patches[(NSUInteger)b.tag][@"code"];
    [self log:@"Da copy code."];
}

- (WKWebView *)findWebView:(UIView *)root {
    if (!root) return nil;
    if ([root isKindOfClass:[WKWebView class]]) return (WKWebView *)root;
    for (UIView *s in root.subviews) {
        WKWebView *r = [self findWebView:s];
        if (r) return r;
    }
    return nil;
}

- (void)onApply:(UIButton *)b {
    NSDictionary *p = self.patches[(NSUInteger)b.tag];
    NSString *kind = p[@"kind"];
    NSString *code = p[@"code"];
    if ([kind isEqualToString:@"patch"]) {
        [self log:ApplyPatchJSON(code)];
    } else if ([kind isEqualToString:@"js"]) {
        WKWebView *wv = [self findWebView:[self keyWindow]];
        if (!wv) {
            [self log:@"Khong tim thay WKWebView trong game (chi dung cho game HTML5/GDevelop)."];
            return;
        }
        [wv evaluateJavaScript:code completionHandler:^(id result, NSError *error) {
            [self log:error ? error.localizedDescription : @"JS da chay."];
        }];
    } else {
        [self log:@"Muc nay khong ap dung truc tiep duoc. Dung Copy Code."];
    }
}

@end

#pragma mark - Entry point

__attribute__((constructor)) static void AIMOLEntry(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[AIMOLUI shared] install];   // chi dung UI; KHONG dump tu dong
    });
}
