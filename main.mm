// AIMOLCore - AI Modder Online (iOS ARM64 dylib)
// Overlay UIKit + Dump IL2CPP thủ công + Memory tool + Gemini/Claude (Vision)
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>

#if __has_include(<dobby.h>)
#import <dobby.h>
#define AIMOL_HAS_DOBBY 1
#endif

#pragma mark - IL2CPP bindings (nạp động, không link cứng)

static void*        (*il_domain_get)(void);
static void**       (*il_domain_get_assemblies)(void *, size_t *);
static void*        (*il_assembly_get_image)(void *);
static size_t       (*il_image_get_class_count)(void *);
static void*        (*il_image_get_class)(void *, size_t);
static const char*  (*il_class_get_name)(void *);
static const char*  (*il_class_get_namespace)(void *);
static void*        (*il_class_get_fields)(void *, void **);
static void*        (*il_class_get_methods)(void *, void **);
static const char*  (*il_field_get_name)(void *);
static size_t       (*il_field_get_offset)(void *);
static const char*  (*il_method_get_name)(void *);
static uint32_t     (*il_method_get_param_count)(void *);
static void*        (*il_thread_attach)(void *);

static BOOL LoadIl2cpp(void) {
    if (il_domain_get) return YES;
    NSString *p = [[NSBundle mainBundle].privateFrameworksPath
                   stringByAppendingString:@"/UnityFramework.framework/UnityFramework"];
    void *h = dlopen(p.UTF8String, RTLD_NOW | RTLD_NOLOAD);
    if (!h) h = dlopen(p.UTF8String, RTLD_NOW);
    if (!h) h = RTLD_DEFAULT;
#define LOAD(n) il_##n = (decltype(il_##n))dlsym(h, "il2cpp_" #n)
    LOAD(domain_get); LOAD(domain_get_assemblies); LOAD(assembly_get_image);
    LOAD(image_get_class_count); LOAD(image_get_class); LOAD(class_get_name);
    LOAD(class_get_namespace); LOAD(class_get_fields); LOAD(class_get_methods);
    LOAD(field_get_name); LOAD(field_get_offset); LOAD(method_get_name);
    LOAD(method_get_param_count); LOAD(thread_attach);
#undef LOAD
    return il_domain_get && il_domain_get_assemblies && il_assembly_get_image &&
           il_image_get_class_count && il_image_get_class && il_class_get_name &&
           il_class_get_fields && il_class_get_methods && il_field_get_name &&
           il_field_get_offset && il_method_get_name && il_thread_attach;
}

#pragma mark - Dump metadata (CHỈ chạy khi người dùng bấm nút)

static NSMutableArray<NSString *> *gCache;   // RAM cache: class chứa từ khóa quan trọng
static NSString *gDumpPath;

static NSString *AIMOLDump(void) {
    if (!LoadIl2cpp()) return @"Không tìm thấy IL2CPP API (game không phải Unity IL2CPP hoặc symbol bị strip).";
    void *dom = il_domain_get();
    if (!dom) return @"il2cpp_domain_get trả về NULL (game chưa khởi tạo xong IL2CPP).";
    il_thread_attach(dom);   // thread nền phải attach trước khi gọi API

    NSArray *kw = @[@"car", @"vehicle", @"physics", @"wheel", @"engine", @"suspension", @"speed"];
    NSMutableString *full = [NSMutableString new];
    NSMutableArray *cache = [NSMutableArray new];
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
            void *it = NULL, *f;
            while ((f = il_class_get_fields(k, &it)))
                [b appendFormat:@"  field %s // offset 0x%zX\n", il_field_get_name(f) ?: "?", il_field_get_offset(f)];
            it = NULL; void *m;
            while ((m = il_class_get_methods(k, &it))) {
                void *ptr = *(void **)m;   // MethodInfo->methodPointer nằm ở offset 0
                Dl_info di; uintptr_t rva = 0;
                if (ptr && dladdr(ptr, &di)) rva = (uintptr_t)ptr - (uintptr_t)di.dli_fbase;
                [b appendFormat:@"  method %s(%u) // ptr=%p RVA=0x%lX\n", il_method_get_name(m) ?: "?",
                 il_method_get_param_count ? il_method_get_param_count(m) : 0, ptr, (unsigned long)rva];
            }
            [full appendString:b];
            NSString *low = b.lowercaseString;
            for (NSString *w in kw) if ([low containsString:w]) { [cache addObject:b]; break; }
        }
    }
    gCache = cache;
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    gDumpPath = [dir stringByAppendingPathComponent:@"AIMOL_dump.txt"];
    [full writeToFile:gDumpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return [NSString stringWithFormat:@"Dump xong: %zu assembly, %zu class, %lu class khớp từ khóa (cache RAM).\nFile đầy đủ: %@",
            asmCount, classTotal, (unsigned long)cache.count, gDumpPath];
}

#pragma mark - Memory tool

static uintptr_t ModuleBase(NSString *name) {
    if (!name.length) name = @"UnityFramework";
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, name.UTF8String)) return (uintptr_t)_dyld_get_image_header(i);
    }
    return (uintptr_t)_dyld_get_image_header(0);
}
static BOOL MemRead(uintptr_t a, void *out, size_t n) {
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), a, n, (vm_address_t)out, &got) == KERN_SUCCESS && got == n;
}
static BOOL MemWrite(uintptr_t a, const void *src, size_t n) {
    vm_protect(mach_task_self(), a, n, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return vm_write(mach_task_self(), a, (vm_offset_t)src, (mach_msg_type_number_t)n) == KERN_SUCCESS;
}
static uintptr_t ParseHex(NSString *s) { return (uintptr_t)strtoull(s.UTF8String, NULL, 16); }

// Patch JSON: {"module":"UnityFramework","offset":"0x1234","pointers":["0x10"],
//              "type":"float|int|bool|bytes","value":123.0}
static NSString *ApplyPatchJSON(NSString *json) {
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                      options:0 error:nil];
    if (![d isKindOfClass:NSDictionary.class] || !d[@"offset"]) return @"JSON patch không hợp lệ (thiếu offset).";
    uintptr_t addr = ModuleBase(d[@"module"]) + ParseHex([d[@"offset"] description]);
    for (id p in (d[@"pointers"] ?: @[])) {
        uintptr_t next = 0;
        if (!MemRead(addr, &next, sizeof next) || !next) return @"Chuỗi pointer lỗi (địa chỉ không đọc được).";
        addr = next + ParseHex([p description]);
    }
    NSString *t = d[@"type"] ?: @"int";
    BOOL ok = NO;
    if ([t isEqualToString:@"float"])      { float v = [d[@"value"] floatValue]; ok = MemWrite(addr, &v, 4); }
    else if ([t isEqualToString:@"int"])   { int32_t v = [d[@"value"] intValue]; ok = MemWrite(addr, &v, 4); }
    else if ([t isEqualToString:@"bool"])  { uint8_t v = [d[@"value"] boolValue]; ok = MemWrite(addr, &v, 1); }
    else if ([t isEqualToString:@"bytes"]) {
        NSString *hex = [[d[@"value"] description] stringByReplacingOccurrencesOfString:@" " withString:@""];
        NSMutableData *buf = [NSMutableData new];
        for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
            uint8_t b = (uint8_t)strtoul([hex substringWithRange:NSMakeRange(i, 2)].UTF8String, NULL, 16);
            [buf appendBytes:&b length:1];
        }
        ok = buf.length && MemWrite(addr, buf.bytes, buf.length);
    } else return [NSString stringWithFormat:@"Kiểu '%@' không hỗ trợ.", t];
    return [NSString stringWithFormat:ok ? @"Đã ghi %@ tại %p." : @"Ghi thất bại tại %p (trang bộ nhớ bị khóa?).", ok ? t : @"", (void *)addr];
}

#ifdef AIMOL_HAS_DOBBY
// Hook qua Dobby (chỉ bật khi có dobby.h + libdobby khi build)
extern "C" int AIMOLHook(void *target, void *replace, void **orig) { return DobbyHook(target, replace, orig); }
#endif

#pragma mark - AI (Gemini / Claude)

static NSString *const kSystemRules =
@"Bạn là AIMOL, trợ lý modding trong game trên iOS. Chỉ trả lời về game, vật lý 3D, thông số xe, bộ nhớ RAM, "
 "kết quả Dump và kỹ thuật modding. Nếu câu hỏi ngoài chủ đề game, hãy từ chối ngắn gọn. Không tự khởi xướng hội thoại. "
 "Trả lời gồm giải thích + số liệu/thông số vật lý chi tiết. Khi đề xuất patch RAM, đưa JSON trong khối ```json với dạng "
 "{\"module\":\"UnityFramework\",\"offset\":\"0x...\",\"pointers\":[],\"type\":\"float\",\"value\":1.0}. "
 "Script JS đặt trong ```js, giao diện HTML đặt trong ```html. Chỉ dùng offset có trong dữ liệu Dump được cung cấp.";

static void AskAI(NSInteger provider, NSString *key, NSString *prompt, NSString *b64, void (^done)(NSString *)) {
    NSString *ctx = @"";
    if (gCache.count) {
        NSString *joined = [[gCache subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)40, gCache.count))] componentsJoinedByString:@"\n"];
        ctx = [NSString stringWithFormat:@"\n\n[DUMP CACHE]\n%@", joined.length > 6000 ? [joined substringToIndex:6000] : joined];
    }
    NSString *text = [prompt stringByAppendingString:ctx];
    NSMutableURLRequest *req; NSDictionary *body;
    if (provider == 0) {
        NSString *url = [NSString stringWithFormat:@"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=%@", key];
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        NSMutableArray *parts = [@[@{@"text": text}] mutableCopy];
        if (b64) [parts addObject:@{@"inline_data": @{@"mime_type": @"image/jpeg", @"data": b64}}];
        body = @{@"system_instruction": @{@"parts": @[@{@"text": kSystemRules}]},
                 @"contents": @[@{@"role": @"user", @"parts": parts}]};
    } else {
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.anthropic.com/v1/messages"]];
        [req setValue:key forHTTPHeaderField:@"x-api-key"];
        [req setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
        NSMutableArray *c = [NSMutableArray new];
        if (b64) [c addObject:@{@"type": @"image", @"source": @{@"type": @"base64", @"media_type": @"image/jpeg", @"data": b64}}];
        [c addObject:@{@"type": @"text", @"text": text}];
        body = @{@"model": @"claude-sonnet-5-5", @"max_tokens": @2048, @"system": kSystemRules,
                 @"messages": @[@{@"role": @"user", @"content": c}]};
    }
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 90;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSString *out;
        if (e) out = [@"Lỗi mạng: " stringByAppendingString:e.localizedDescription];
        else {
            id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            NSString *t = provider == 0 ? j[@"candidates"][0][@"content"][@"parts"][0][@"text"]
                                        : j[@"content"][0][@"text"];
            out = t ?: [NSString stringWithFormat:@"API trả lỗi: %@", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(out); });
    }] resume];
}

#pragma mark - Overlay UI

static NSString *const kPatchStore = @"aimol.patches";

@interface AIMOLUI : NSObject <UITableViewDataSource, UITableViewDelegate>
@property UIButton *floatBtn, *dumpBtn, *sendBtn;
@property UIView *panel, *tabChat;
@property UISegmentedControl *tabSeg, *provSeg;
@property UITextField *geminiKey, *claudeKey, *input;
@property UITextView *chat;
@property UITableView *table;
@property NSMutableArray<NSDictionary *> *patches;
+ (instancetype)shared;
- (void)install;
@end

@implementation AIMOLUI

+ (instancetype)shared { static AIMOLUI *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = AIMOLUI.new; }); return s; }

- (UIWindow *)keyWindow {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class] && sc.activationState == UISceneActivationStateForegroundActive)
            for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
    return nil;
}

- (UITextField *)field:(NSString *)ph frame:(CGRect)f secure:(BOOL)sec key:(NSString *)k {
    UITextField *t = [[UITextField alloc] initWithFrame:f];
    t.placeholder = ph; t.secureTextEntry = sec; t.borderStyle = UITextBorderStyleRoundedRect;
    t.font = [UIFont systemFontOfSize:13]; t.autocapitalizationType = UITextAutocapitalizationTypeNone;
    t.autocorrectionType = UITextAutocorrectionTypeNo;
    if (k) {
        t.text = [NSUserDefaults.standardUserDefaults stringForKey:k];
        [t addTarget:self action:@selector(saveKeys) forControlEvents:UIControlEventEditingChanged];
    }
    return t;
}

- (void)saveKeys {
    [NSUserDefaults.standardUserDefaults setObject:_geminiKey.text forKey:@"aimol.gemini"];
    [NSUserDefaults.standardUserDefaults setObject:_claudeKey.text forKey:@"aimol.claude"];
}

- (void)install {
    UIWindow *w = [self keyWindow];
    if (!w) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self install]; }); return; }
    _patches = [[NSUserDefaults.standardUserDefaults arrayForKey:kPatchStore] mutableCopy] ?: [NSMutableArray new];

    CGFloat pw = MIN(w.bounds.size.width - 20, 420), ph = w.bounds.size.height * 0.48;
    _panel = [[UIView alloc] initWithFrame:CGRectMake((w.bounds.size.width - pw) / 2, w.safeAreaInsets.top + 70, pw, ph)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    _panel.layer.cornerRadius = 14; _panel.clipsToBounds = YES; _panel.hidden = YES;
    _panel.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, 80, 32)];
    title.text = @"AIMOL"; title.textColor = UIColor.whiteColor; title.font = [UIFont boldSystemFontOfSize:17];
    [_panel addSubview:title];
    _dumpBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _dumpBtn.frame = CGRectMake(pw - 150, 6, 140, 32);
    [_dumpBtn setTitle:@"DUMP METADATA" forState:UIControlStateNormal];
    _dumpBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [_dumpBtn addTarget:self action:@selector(onDump) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_dumpBtn];

    _tabSeg = [[UISegmentedControl alloc] initWithItems:@[@"CHAT AI", @"KHU LƯU TRỮ"]];
    _tabSeg.frame = CGRectMake(10, 42, pw - 20, 30); _tabSeg.selectedSegmentIndex = 0;
    [_tabSeg addTarget:self action:@selector(onTab) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:_tabSeg];

    CGFloat y0 = 78, cw = pw - 20, ch = ph - y0;
    _tabChat = [[UIView alloc] initWithFrame:CGRectMake(10, y0, cw, ch)];
    _provSeg = [[UISegmentedControl alloc] initWithItems:@[@"Gemini", @"Claude"]];
    _provSeg.frame = CGRectMake(0, 0, cw, 28); _provSeg.selectedSegmentIndex = 0;
    _geminiKey = [self field:@"Gemini API Key" frame:CGRectMake(0, 32, cw / 2 - 2, 30) secure:YES key:@"aimol.gemini"];
    _claudeKey = [self field:@"Claude API Key" frame:CGRectMake(cw / 2 + 2, 32, cw / 2 - 2, 30) secure:YES key:@"aimol.claude"];
    _chat = [[UITextView alloc] initWithFrame:CGRectMake(0, 66, cw, ch - 66 - 38)];
    _chat.editable = NO; _chat.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    _chat.textColor = UIColor.whiteColor; _chat.font = [UIFont systemFontOfSize:13]; _chat.layer.cornerRadius = 8;
    _input = [self field:@"Nhập câu hỏi..." frame:CGRectMake(0, ch - 34, cw - 64, 32) secure:NO key:nil];
    _sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _sendBtn.frame = CGRectMake(cw - 60, ch - 34, 60, 32);
    [_sendBtn setTitle:@"Gửi" forState:UIControlStateNormal];
    [_sendBtn addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *v in @[_provSeg, _geminiKey, _claudeKey, _chat, _input, _sendBtn]) [_tabChat addSubview:v];
    [_panel addSubview:_tabChat];

    _table = [[UITableView alloc] initWithFrame:CGRectMake(10, y0, cw, ch) style:UITableViewStylePlain];
    _table.backgroundColor = UIColor.clearColor; _table.dataSource = self; _table.delegate = self;
    _table.rowHeight = 74; _table.hidden = YES;
    [_panel addSubview:_table];
    [w addSubview:_panel];

    _floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _floatBtn.frame = CGRectMake(w.bounds.size.width - 76, w.bounds.size.height * 0.35, 56, 56);
    _floatBtn.backgroundColor = UIColor.blackColor;                      // #000000
    [_floatBtn setTitle:@"AIMOL" forState:UIControlStateNormal];
    [_floatBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];  // #FFFFFF
    _floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    _floatBtn.titleLabel.textAlignment = NSTextAlignmentCenter;
    _floatBtn.layer.cornerRadius = 28;
    _floatBtn.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor; _floatBtn.layer.borderWidth = 1;
    [_floatBtn addTarget:self action:@selector(onFloat) forControlEvents:UIControlEventTouchUpInside];
    [_floatBtn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];
    [w addSubview:_floatBtn];
    [self log:@"Sẵn sàng. AIMOL đang ở chế độ chờ."];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view; CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
    [v.superview bringSubviewToFront:_panel]; [v.superview bringSubviewToFront:v];
}
- (void)onFloat { _panel.hidden = !_panel.hidden; if (!_panel.hidden) [_panel.superview bringSubviewToFront:_panel], [_panel.superview bringSubviewToFront:_floatBtn]; }
- (void)onTab { _tabChat.hidden = _tabSeg.selectedSegmentIndex != 0; _table.hidden = !_tabChat.hidden; [_table reloadData]; [_input resignFirstResponder]; }

- (void)log:(NSString *)s {
    _chat.text = [(_chat.text ?: @"") stringByAppendingFormat:@"%@\n\n", s];
    [_chat scrollRangeToVisible:NSMakeRange(_chat.text.length, 0)];
}

- (void)onDump {
    [_dumpBtn setTitle:@"Đang dump..." forState:UIControlStateNormal]; _dumpBtn.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *r = AIMOLDump();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self log:r];
            [self.dumpBtn setTitle:@"DUMP METADATA" forState:UIControlStateNormal]; self.dumpBtn.enabled = YES;
        });
    });
}

- (NSString *)snapshotB64 {
    UIWindow *w = [self keyWindow]; if (!w) return nil;
    _panel.hidden = YES; _floatBtn.hidden = YES;   // không chụp chính overlay
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat]; fmt.scale = 1.0;
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:w.bounds.size format:fmt]
                    imageWithActions:^(UIGraphicsImageRendererContext *c) { [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:YES]; }];
    _floatBtn.hidden = NO; _panel.hidden = NO;
    return [UIImageJPEGRepresentation(img, 0.5) base64EncodedStringWithOptions:0];
}

- (void)onSend {
    NSString *q = [_input.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!q.length) return;
    NSInteger prov = _provSeg.selectedSegmentIndex;
    NSString *key = prov == 0 ? _geminiKey.text : _claudeKey.text;
    if (!key.length) { [self log:@"Chưa nhập API Key cho nhà cung cấp đã chọn."]; return; }
    _input.text = @""; [_input resignFirstResponder];
    [self log:[@"Bạn: " stringByAppendingString:q]];
    _sendBtn.enabled = NO;
    NSString *b64 = [self snapshotB64];
    AskAI(prov, key, q, b64, ^(NSString *reply) {
        self.sendBtn.enabled = YES;
        [self log:[@"AI: " stringByAppendingString:reply]];
        [self harvestCode:reply];
    });
}

// Tự lưu các khối code AI trả về vào Khu lưu trữ
- (void)harvestCode:(NSString *)reply {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"```(\\w*)\\n([\\s\\S]*?)```" options:0 error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:reply options:0 range:NSMakeRange(0, reply.length)]) {
        NSString *lang = [reply substringWithRange:[m rangeAtIndex:1]].lowercaseString;
        NSString *code = [reply substringWithRange:[m rangeAtIndex:2]];
        NSString *kind = ([lang isEqualToString:@"json"] || [lang isEqualToString:@"aimol"]) ? @"patch"
                       : [lang hasPrefix:@"js"] || [lang isEqualToString:@"javascript"] ? @"js"
                       : [lang isEqualToString:@"html"] ? @"html" : @"text";
        [_patches insertObject:@{@"kind": kind, @"code": code, @"title": [NSString stringWithFormat:@"[%@] %@", kind.uppercaseString, [[code componentsSeparatedByString:@"\n"].firstObject substringToIndex:MIN((NSUInteger)40, [code componentsSeparatedByString:@"\n"].firstObject.length)]]} atIndex:0];
    }
    [NSUserDefaults.standardUserDefaults setObject:_patches forKey:kPatchStore];
    [_table reloadData];
}

#pragma mark table (TAB 2)

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _patches.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
    c.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    [c.contentView.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    CGFloat w = t.bounds.size.width;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 4, w - 20, 26)];
    l.text = _patches[ip.row][@"title"]; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:13];
    [c.contentView addSubview:l];
    NSArray *titles = @[@"Áp dụng ngay", @"Copy Code"]; SEL sels[] = {@selector(onApply:), @selector(onCopy:)};
    for (int i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(10 + i * (w / 2 - 5), 34, w / 2 - 15, 32); b.tag = ip.row;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b addTarget:self action:sels[i] forControlEvents:UIControlEventTouchUpInside];
        [c.contentView addSubview:b];
    }
    return c;
}
- (void)onCopy:(UIButton *)b { UIPasteboard.generalPasteboard.string = _patches[b.tag][@"code"]; [self log:@"Đã copy code."]; }

- (WKWebView *)findWeb:(UIView *)v {
    if ([v isKindOfClass:WKWebView.class]) return (WKWebView *)v;
    for (UIView *s in v.subviews) { WKWebView *r = [self findWeb:s]; if (r) return r; }
    return nil;
}
- (void)onApply:(UIButton *)b {
    NSDictionary *p = _patches[b.tag]; NSString *kind = p[@"kind"], *code = p[@"code"];
    if ([kind isEqualToString:@"patch"]) [self log:ApplyPatchJSON(code)];
    else if ([kind isEqualToString:@"js"]) {
        WKWebView *wv = [self findWeb:[self keyWindow]];
        if (!wv) { [self log:@"Không tìm thấy WKWebView trong game (chỉ dùng cho game HTML5/GDevelop)."]; return; }
        [wv evaluateJavaScript:code completionHandler:^(id r, NSError *e) { [self log:e ? e.localizedDescription : @"JS đã chạy."]; }];
    } else [self log:@"Mục này không áp dụng trực tiếp được. Dùng Copy Code."];
}
@end

#pragma mark - Entry point

__attribute__((constructor)) static void AIMOLEntry(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[AIMOLUI shared] install];   // chỉ dựng UI; KHÔNG dump tự động
    });
}
