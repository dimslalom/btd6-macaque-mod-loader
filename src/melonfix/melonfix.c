// melonfix v13: makes MelonLoader 0.7.3 (macOS x64) work for BTD6 under Rosetta. Injected before the Bootstrap.
//  1. routes UnityPlayer's dlsym lookups into MelonLoader's SymbolDetour (its plthook writes land at slot+delta)
//  2. swaps the main executable to dyld image 0 for MelonLoader's image queries
//  3. reports GameAssembly's exact size to ProcessModulesFix (stops Il2CppInterop's scan from running off the end)
//  4. retargets Il2CppInterop hooks that its xref fallbacks put on the wrong function (resolved via GameAssembly's
//     symbol table): Class::GetFieldDefaultValue and GlobalMetadata::GetTypeInfoFromTypeDefinitionIndex
//  4b. refuses Harmony hooks on methods taking non-blittable structs by value (SysV passes them in registers or on
//     the stack, Il2CppInterop's trampoline assumes a pointer and crashes); logged as SKIP. Not needed when the
//     MelonMacFixes plugin is installed: it fixes the trampolines and calls melonfix_set_abi_fixed(1).
//  5. resolves dlopen("GameAssembly.dylib") to the Frameworks copy
//  6. redirects .NET reads of the universal GameAssembly.dylib to the thinned x86_64 copy Cpp2IL used
//  7. clears DYLD_INSERT_LIBRARIES so child processes (Cpp2IL) start clean
//  8. runs MelonLoader's Cpp2IL through _modkit/cpp2il-wrapper.sh (execve/posix_spawn redirect), so the wrapper keeps
//     working when MelonLoader re-downloads Cpp2IL
// Set MELONFIX_DEBUG=1 for verbose melonfix.log output and a native crash backtrace in melonfix.log.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
static const struct mach_header_64 *up_mh = NULL; static intptr_t up_slide = 0;

typedef void* (*dlsym_fn)(void*, const char*);
static int fd = -1, dbg = 0;   // dbg: MELONFIX_DEBUG=1 enables verbose logging (lgv)
static void lg(const char *fmt, ...) {
  if (fd < 0) { const char *d = getenv("MELONFIX_DIR"); char p[2048];
    snprintf(p, sizeof p, "%s/melonfix.log", d ? d : "/tmp");
    fd = open(p, O_WRONLY|O_CREAT|O_TRUNC, 0644); }
  char b[1024]; va_list ap; va_start(ap, fmt);
  int n = vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
  if (fd >= 0 && n > 0) write(fd, b, n < (int)sizeof b ? n : (int)sizeof b - 1);
}
#define lgv(...) do { if (dbg) lg(__VA_ARGS__); } while (0)

typedef struct { uintptr_t start; size_t size; uintptr_t *snap; int skip; const char *img; } seg_t;
static seg_t segs[32]; static int nsegs = 0;
static uintptr_t up_lo = 0, up_hi = 0;
static dlsym_fn detour = NULL;
static int searched = 0;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
void* fix_dlsym(void *h, const char *n);

static int is_dlsym_ptr(uintptr_t v) {
  if (!v) return 0;
  if (v == (uintptr_t)&fix_dlsym || v == (uintptr_t)&dlsym) return 1;
  Dl_info i; return dladdr((void*)v, &i) && i.dli_sname && i.dli_saddr == (void*)v && strcmp(i.dli_sname, "dlsym") == 0;
}
static const char* nm(uintptr_t v, char *buf, size_t n) {
  Dl_info i; if (v && dladdr((void*)v, &i)) { const char *f = i.dli_fname ? strrchr(i.dli_fname,'/') : 0;
    snprintf(buf, n, "%s!%s", f ? f+1 : "?", i.dli_sname ? i.dli_sname : "?"); }
  else snprintf(buf, n, "<anon>"); return buf; }

static void snapshot_unityplayer(void) {
  for (uint32_t k = 0; k < _dyld_image_count(); k++) {
    const char *name = _dyld_get_image_name(k);
    if (!name || !strncmp(name, "/System/", 8) || !strncmp(name, "/usr/", 5)) continue;
    int isup = strstr(name, "/UnityPlayer.dylib") != NULL;
    const char *bn = strrchr(name, '/'); bn = bn ? bn + 1 : name;
    if (strstr(name, "melonfix")) continue;
    const struct mach_header_64 *mh = (const void*)_dyld_get_image_header(k);
    intptr_t slide = _dyld_get_image_vmaddr_slide(k);
    const uint8_t *p = (const uint8_t*)(mh + 1);
    for (uint32_t c = 0; c < mh->ncmds; c++) {
      const struct load_command *lc = (const void*)p;
      if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *sg = (const void*)p;
        if (isup) { up_mh = mh; up_slide = slide; }
        if (isup && !strcmp(sg->segname, "__TEXT")) { up_lo = sg->vmaddr + slide; up_hi = up_lo + sg->vmsize; }
        if (!strncmp(sg->segname, "__DATA", 6) && nsegs < 32 && sg->vmsize < (64u<<20)) {
          seg_t *s = &segs[nsegs++]; s->start = sg->vmaddr + slide; s->size = sg->vmsize;
          s->snap = malloc(s->size); memcpy(s->snap, (void*)s->start, s->size);
          s->skip = strstr(name, "MelonLoader.Bootstrap") != NULL; s->img = strdup(bn);
          lgv("snap %s %s %p size=%zu\n", bn, sg->segname, (void*)s->start, s->size);
        }
      }
      p += lc->cmdsize;
    }
  }
  lgv("UnityPlayer text %p-%p\n", (void*)up_lo, (void*)up_hi);
}

// Walk UnityPlayer's symbol-pointer sections (lazy + non-lazy) and name each slot via the indirect symbol table.
static uintptr_t gaddr[4]; static const char *gname[4] = {"_dlsym","_dup2","_fopen","_vfprintf"};
static int changed_anon(uintptr_t addr) {
  for (int i = 0; i < nsegs; i++) { if (segs[i].skip) continue;
    if (addr >= segs[i].start && addr + 8 <= segs[i].start + segs[i].size) {
      size_t j = (addr - segs[i].start) / 8; uintptr_t o = segs[i].snap[j], v = *(uintptr_t*)addr;
      Dl_info di; return o != v && v && !dladdr((void*)v, &di); } }
  return 0; }

static void find_detour(void) {
  searched = 1;
  if (!up_mh) { lg("no UnityPlayer header\n"); return; }
  const uint8_t *p = (const uint8_t*)(up_mh + 1);
  const struct symtab_command *st = NULL; const struct dysymtab_command *dy = NULL;
  const struct segment_command_64 *le = NULL;
  for (uint32_t c = 0; c < up_mh->ncmds; c++) { const struct load_command *lc = (const void*)p;
    if (lc->cmd == LC_SYMTAB) st = (const void*)p;
    if (lc->cmd == LC_DYSYMTAB) dy = (const void*)p;
    if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64*)p)->segname, "__LINKEDIT")) le = (const void*)p;
    p += lc->cmdsize; }
  if (!st || !dy || !le) { lg("missing symtab/dysymtab/linkedit\n"); return; }
  uintptr_t lebase = le->vmaddr + up_slide - le->fileoff;
  const struct nlist_64 *syms = (const void*)(lebase + st->symoff);
  const char *strs = (const char*)(lebase + st->stroff);
  const uint32_t *ind = (const uint32_t*)(lebase + dy->indirectsymoff);
  p = (const uint8_t*)(up_mh + 1);
  for (uint32_t c = 0; c < up_mh->ncmds; c++) { const struct load_command *lc = (const void*)p;
    if (lc->cmd == LC_SEGMENT_64) { const struct segment_command_64 *sg = (const void*)p;
      const struct section_64 *sec = (const void*)(sg + 1);
      for (uint32_t k = 0; k < sg->nsects; k++, sec++) {
        uint32_t type = sec->flags & SECTION_TYPE;
        if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
        uintptr_t *slots = (uintptr_t*)(sec->addr + up_slide); size_t n = sec->size / 8;
        for (size_t j = 0; j < n; j++) {
          uint32_t si = ind[sec->reserved1 + j];
          if (si & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
          const char *name = strs + syms[si].n_un.n_strx;
          if (strcmp(name, "_dlsym") && strcmp(name, "_fopen") && strcmp(name, "_dup2") && strcmp(name, "_vfprintf")) continue;
          char a[300]; uintptr_t v = slots[j];
          for (int g = 0; g < 4; g++) if (!strcmp(name, gname[g]) && !gaddr[g]) gaddr[g] = (uintptr_t)&slots[j];
          lgv("slot %s,%s[%zu] %s = %p (%s)\n", sec->segname, sec->sectname, j, name, (void*)v, nm(v, a, 300));
          if (!strcmp(name, "_dlsym") && v && !is_dlsym_ptr(v) && !detour) {
            Dl_info di; if (!dladdr((void*)v, &di) || (di.dli_fname && strstr(di.dli_fname, "MelonLoader"))) detour = (dlsym_fn)v; }
        }
      } }
    p += lc->cmdsize; }
  // MelonLoader's plthook writes to (correct slot + constant delta) on this build. Find that delta.
  if (!detour && gaddr[0]) {
    for (int i = 0; i < nsegs && !detour; i++) { if (segs[i].skip) continue;
      size_t cnt = segs[i].size / 8;
      for (size_t j = 0; j < cnt && !detour; j++) {
        uintptr_t addr = segs[i].start + j * 8;
        if (!changed_anon(addr)) continue;
        intptr_t d = (intptr_t)addr - (intptr_t)gaddr[0]; int ok = 1, others = 0;
        for (int g = 1; g < 4; g++) if (gaddr[g]) { others++; if (!changed_anon(gaddr[g] + d)) { ok = 0; break; } }
        if (ok && others >= 2) { detour = (dlsym_fn)*(uintptr_t*)addr;
          lg("misplaced hook delta=%ld (0x%lx) dlsym hook at %p = %p\n", (long)d, (long)d, (void*)addr, (void*)detour);
          for (int g = 1; g < 4; g++) if (gaddr[g]) lgv("  %s hook at %p = %p\n", gname[g], (void*)(gaddr[g]+d), (void*)*(uintptr_t*)(gaddr[g]+d)); }
      } }
  }
  lg(detour ? "detour found %p\n" : "detour NOT found\n", (void*)detour);
}

// dyld image list with the main executable swapped to index 0 (MelonLoader assumes image[0] is the game).
static int32_t main_idx = -1;
static uint32_t remap(uint32_t i) {
  if (main_idx < 0) { main_idx = 0;
    for (uint32_t k = 0; k < _dyld_image_count(); k++) { const struct mach_header *h = _dyld_get_image_header(k);
      if (h && h->filetype == MH_EXECUTE) { main_idx = (int32_t)k; break; } }
    lgv("main executable is dyld image %d\n", main_idx); }
  if (i == 0) return (uint32_t)main_idx;
  if (i == (uint32_t)main_idx) return 0;
  return i; }
static const char* w_image_name(uint32_t i) { return _dyld_get_image_name(remap(i)); }
// ProcessModulesFix sizes a module as sizeof(header)+sizeofcmds+sum(segment vmsize), which overshoots the real
// image by a page or so. Il2CppInterop then scans GameAssembly linearly to that bogus end and faults once the
// neighbouring mapping goes away. For GameAssembly, hand back a copy of header+load commands where __LINKEDIT is one
// page shorter and sizeofcmds pads the total back to exactly the image span (the walk only uses ncmds/cmdsize).
static const struct mach_header *ga_fake = NULL;
static const struct mach_header* fake_ga_header(const struct mach_header_64 *mh) {
  if (ga_fake) return ga_fake;
  size_t n = sizeof(*mh) + mh->sizeofcmds; struct mach_header_64 *c = malloc(n); memcpy(c, mh, n);
  uint64_t lo = UINT64_MAX, hi = 0, sum = 0; struct segment_command_64 *le = NULL; uint8_t *p = (uint8_t*)(c + 1);
  for (uint32_t k = 0; k < c->ncmds; k++) { struct load_command *lc = (void*)p;
    if (lc->cmd == LC_SEGMENT_64) { struct segment_command_64 *sg = (void*)p;
      if (strcmp(sg->segname, "__PAGEZERO")) { if (sg->vmaddr < lo) lo = sg->vmaddr; if (sg->vmaddr + sg->vmsize > hi) hi = sg->vmaddr + sg->vmsize; }
      sum += sg->vmsize; if (!strcmp(sg->segname, "__LINKEDIT")) le = sg; }
    p += lc->cmdsize; }
  uint64_t span = hi - lo, cut = 0x1000;
  if (!le || le->vmsize <= cut || sum - cut + sizeof(*c) > span) { lg("ga header: cannot fix (sum=0x%llx span=0x%llx)\n", sum, span); free(c); return ga_fake = (const void*)mh; }
  le->vmsize -= cut; c->sizeofcmds = (uint32_t)(span - (sum - cut) - sizeof(*c));
  lg("ga header: reported size now 0x%llx (span 0x%llx)\n", sizeof(*c) + c->sizeofcmds + sum - cut, span);
  return ga_fake = (const void*)c; }
static const struct mach_header* w_image_header(uint32_t i) {
  uint32_t r = remap(i); const struct mach_header *h = _dyld_get_image_header(r); const char *n = _dyld_get_image_name(r);
  if (h && h->magic == MH_MAGIC_64 && n && strstr(n, "/GameAssembly.dylib")) return fake_ga_header((const void*)h);
  return h; }
static intptr_t w_image_slide(uint32_t i) { return _dyld_get_image_vmaddr_slide(remap(i)); }

// GameAssembly ships with full local symbols; look one up by a substring of its mangled name.
static uintptr_t ga_sym(const char *needle) {
  for (uint32_t k = 0; k < _dyld_image_count(); k++) {
    const char *in = _dyld_get_image_name(k); if (!in || !strstr(in, "/GameAssembly.dylib")) continue;
    const struct mach_header_64 *mh = (const void*)_dyld_get_image_header(k); intptr_t slide = _dyld_get_image_vmaddr_slide(k);
    const struct symtab_command *st = NULL; const struct segment_command_64 *le = NULL; const uint8_t *p = (const uint8_t*)(mh + 1);
    for (uint32_t c = 0; c < mh->ncmds; c++) { const struct load_command *lc = (const void*)p;
      if (lc->cmd == LC_SYMTAB) st = (const void*)p;
      if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64*)p)->segname, "__LINKEDIT")) le = (const void*)p;
      p += lc->cmdsize; }
    if (!st || !le) return 0;
    uintptr_t lebase = le->vmaddr + slide - le->fileoff;
    const struct nlist_64 *sy = (const void*)(lebase + st->symoff); const char *strs = (const char*)(lebase + st->stroff);
    for (uint32_t i = 0; i < st->nsyms; i++)
      if ((sy[i].n_type & N_TYPE) == N_SECT && !(sy[i].n_type & N_STAB) && strstr(strs + sy[i].n_un.n_strx, needle))
        return sy[i].n_value + slide;
    return 0; }
  return 0; }

// Il2CppInterop's xref fallbacks pick the wrong function on this build (macOS clang, non-Master il2cpp). Each hook's
// detour expects a different signature than what it lands on, which corrupts or crashes the game. Retarget by symbol.
static const struct { const char *wrong, *right, *what; } retargets[] = {
  { "BlobReader24GetConstantValueFromBlob", "2vm5Class20GetFieldDefaultValueE",
    "Class::GetFieldDefaultValue (xref hit BlobReader::GetConstantValueFromBlob)" },
  { "2vm14GlobalMetadata21GetAssemblyTypeHandleE", "2vm14GlobalMetadata34GetTypeInfoFromTypeDefinitionIndexEi",
    "GetTypeInfoFromTypeDefinitionIndex (xref hit GlobalMetadata::GetAssemblyTypeHandle)" },
};
#define NRETARGET (sizeof retargets / sizeof retargets[0])
// ---- il2cpp method lookup (for ABI checks on hooked methods) ----
typedef struct { void *methodPointer; } MethodInfoHead;   // methodPointer is the first field of MethodInfo
static struct { void *(*domain_get)(void); void **(*domain_get_assemblies)(void*, size_t*); void *(*assembly_get_image)(void*);
  size_t (*image_get_class_count)(void*); void *(*image_get_class)(void*, size_t); void *(*class_get_methods)(void*, void**);
  void *(*class_get_nested_types)(void*, void**);
  uint32_t (*method_get_param_count)(void*); void *(*method_get_param)(void*, uint32_t); void *(*method_get_return_type)(void*);
  const char *(*method_get_name)(void*); void *(*method_get_class)(void*); const char *(*class_get_name)(void*);
  int (*type_get_type)(void*); void *(*class_from_type)(void*); int (*class_is_enum)(void*); int32_t (*class_value_size)(void*, uint32_t*);
  void *(*class_get_fields)(void*, void**); void *(*field_get_type)(void*); int (*type_is_static)(void*); size_t (*field_get_offset)(void*);
  int (*field_get_flags)(void*); int (*class_is_valuetype)(void*); } il;
static int il_ok = -1;
static int il_init(void) {
  if (il_ok >= 0) return il_ok;
  void *h = dlopen("@executable_path/../Frameworks/GameAssembly.dylib", RTLD_NOLOAD | RTLD_LAZY);
  if (!h) for (uint32_t k = 0; k < _dyld_image_count(); k++) { const char *in = _dyld_get_image_name(k);
    if (in && strstr(in, "/GameAssembly.dylib")) { h = dlopen(in, RTLD_NOLOAD | RTLD_LAZY); break; } }
#define R(f) *(void**)&il.f = h ? dlsym(h, "il2cpp_" #f) : NULL; if (!il.f) { lg("il2cpp_%s missing\n", #f); return il_ok = 0; }
  R(domain_get) R(domain_get_assemblies) R(assembly_get_image) R(image_get_class_count) R(image_get_class) R(class_get_methods)
  R(class_get_nested_types) R(method_get_param_count) R(method_get_param) R(method_get_return_type) R(method_get_name) R(method_get_class)
  R(class_get_name) R(type_get_type) R(class_from_type) R(class_is_enum) R(class_value_size) R(class_get_fields) R(field_get_type)
  R(field_get_offset) R(field_get_flags) R(class_is_valuetype)
#undef R
  return il_ok = 1; }
// methodPointer -> MethodInfo* map (open addressing)
static uintptr_t *mp_keys; static void **mp_vals; static size_t mp_cap;
static void mp_put(uintptr_t k, void *v) { size_t i = (k >> 4) & (mp_cap - 1);
  while (mp_keys[i] && mp_keys[i] != k) i = (i + 1) & (mp_cap - 1); if (!mp_keys[i]) { mp_keys[i] = k; mp_vals[i] = v; } }
static void *mp_get(uintptr_t k) { if (!mp_cap) return NULL; size_t i = (k >> 4) & (mp_cap - 1);
  while (mp_keys[i]) { if (mp_keys[i] == k) return mp_vals[i]; i = (i + 1) & (mp_cap - 1); } return NULL; }
static void mp_add_class(void *k, int depth) {
  void *it = NULL, *m; while ((m = il.class_get_methods(k, &it))) { void *ptr = ((MethodInfoHead*)m)->methodPointer; if (ptr) mp_put((uintptr_t)ptr, m); }
  if (depth < 4) { void *it2 = NULL, *n; while ((n = il.class_get_nested_types(k, &it2))) mp_add_class(n, depth + 1); } }
static void mp_build(void) {
  if (mp_cap || !il_init()) return;
  mp_cap = 1 << 20; mp_keys = calloc(mp_cap, sizeof *mp_keys); mp_vals = calloc(mp_cap, sizeof *mp_vals);
  size_t na = 0; void **as = il.domain_get_assemblies(il.domain_get(), &na); size_t cnt = 0;
  for (size_t a = 0; a < na; a++) { void *img = il.assembly_get_image(as[a]); size_t nc = il.image_get_class_count(img);
    for (size_t c = 0; c < nc; c++) { mp_add_class(il.image_get_class(img, c), 0); cnt++; } }
  lg("method map: %zu assemblies, %zu classes\n", na, cnt); }

// SysV classification of a by-value struct: returns size, fills cls[0..1] with 'I' (integer) or 'S' (sse) per eightbyte, 'M' if memory.
#define IL2CPP_TYPE_R4 0x0c
#define IL2CPP_TYPE_R8 0x0d
#define IL2CPP_TYPE_VALUETYPE 0x11
#define IL2CPP_TYPE_GENERICINST 0x15
// Il2CppInterop generates blittable structs (only primitive/blittable-struct fields) as real C# structs, which .NET
// marshals with the platform ABI. Non-blittable ones (any reference field, or generic instances) become
// Il2CppSystem.ValueType wrappers that its trampoline always treats as "passed by pointer" (Windows x64 rule).
static int nonblittable_class(void *k, int depth) {
  if (depth > 6) return 1; void *it = NULL, *f;
  while ((f = il.class_get_fields(k, &it))) { if (il.field_get_flags(f) & 0x10) continue;
    void *ft = il.field_get_type(f); int tt = il.type_get_type(ft);
    if ((tt >= 0x02 && tt <= 0x0d) || tt == 0x0f || tt == 0x18 || tt == 0x19 || tt == 0x1b) continue;   // primitives, ptr, I, U, fnptr
    if (tt == IL2CPP_TYPE_VALUETYPE) { void *fk = il.class_from_type(ft); if (fk && (il.class_is_enum(fk) || !nonblittable_class(fk, depth + 1))) continue; }
    return 1; }
  return 0; }
static int is_struct_type(void *t) { int tt = il.type_get_type(t);
  if (tt != IL2CPP_TYPE_VALUETYPE && tt != IL2CPP_TYPE_GENERICINST) return 0;
  void *k = il.class_from_type(t); if (!k || il.class_is_enum(k) || !il.class_is_valuetype(k)) return 0;
  if (tt == IL2CPP_TYPE_GENERICINST) return 1;   // generic structs are always wrappers
  return nonblittable_class(k, 0); }
static void classify_fields(void *k, size_t base, char cls[2], int depth) {
  void *it = NULL, *f;
  while ((f = il.class_get_fields(k, &it))) { if (il.field_get_flags(f) & 0x10) continue;   // FIELD_ATTRIBUTE_STATIC
    void *ft = il.field_get_type(f); size_t off = base + il.field_get_offset(f) - 16;      // instance offsets include the object header
    int tt = il.type_get_type(ft);
    if ((tt == IL2CPP_TYPE_VALUETYPE || tt == IL2CPP_TYPE_GENERICINST) && depth < 6) { void *fk = il.class_from_type(ft);
      if (fk && !il.class_is_enum(fk)) { classify_fields(fk, off, cls, depth + 1); continue; } }
    int eb = off >= 8; if (eb > 1) continue;
    if (!(tt == IL2CPP_TYPE_R4 || tt == IL2CPP_TYPE_R8)) cls[eb] = 'I'; else if (cls[eb] != 'I') cls[eb] = 'S'; } }
static int classify_struct(void *t, char cls[2]) {
  void *k = il.class_from_type(t); uint32_t al = 0; int sz = il.class_value_size(k, &al);
  cls[0] = cls[1] = 0; if (sz > 16) { cls[0] = cls[1] = 'M'; return sz; }
  classify_fields(k, 0, cls, 0); if (!cls[0]) cls[0] = 'I'; if (sz > 8 && !cls[1]) cls[1] = 'I'; return sz; }
// Does this method's native signature differ from what Il2CppInterop's trampoline assumes (Windows x64 rules)?
static int abi_mismatch(void *m, char *why, size_t n) {
  why[0] = 0; int bad = 0; uint32_t pc = il.method_get_param_count(m); size_t w = 0;
  for (uint32_t i = 0; i < pc; i++) { void *t = il.method_get_param(m, i); if (!is_struct_type(t)) continue;
    char c[2]; int sz = classify_struct(t, c);
    bad = 1; w += snprintf(why + w, w < n ? n - w : 0, "arg%u:%s(%d,%c%c) ", i, il.class_get_name(il.class_from_type(t)), sz, c[0], c[1] ? c[1] : '-'); }
  void *rt = il.method_get_return_type(m);
  if (rt && is_struct_type(rt)) { char c[2]; int sz = classify_struct(rt, c);
    if (sz <= 16 && (sz > 8 || c[0] == 'S')) { bad = 1; w += snprintf(why + w, w < n ? n - w : 0, "ret:%s(%d,%c%c)", il.class_get_name(il.class_from_type(rt)), sz, c[0], c[1] ? c[1] : '-'); } }
  return bad; }

// Set by the MelonMacFixes plugin once it has patched Il2CppInterop's Harmony trampolines for the SysV struct ABI.
static int abi_fixed = 0;
__attribute__((visibility("default"))) void melonfix_set_abi_fixed(int v) { abi_fixed = v; lg("SysV struct ABI handled by MelonMacFixes\n"); }

typedef void (*hook_fn)(void **target, void *detour);
static hook_fn real_hook_attach = NULL;
static uintptr_t rt_wrong[NRETARGET], rt_right[NRETARGET]; static int syms_done = 0;
static void name_addr(uintptr_t a, char *out, size_t n);
static void w_hook_attach(void **target, void *detour) {
  if (!syms_done) { syms_done = 1;
    for (size_t i = 0; i < NRETARGET; i++) { rt_wrong[i] = ga_sym(retargets[i].wrong); rt_right[i] = ga_sym(retargets[i].right);
      if (!rt_wrong[i] || !rt_right[i]) lg("retarget symbols missing for %s (wrong=%p right=%p)\n", retargets[i].what, (void*)rt_wrong[i], (void*)rt_right[i]); } }
  if (target) {
    for (size_t i = 0; i < NRETARGET; i++)
      if (rt_wrong[i] && rt_right[i] && (uintptr_t)*target == rt_wrong[i]) {
        lg("hook retarget %p -> %p: %s\n", *target, (void*)rt_right[i], retargets[i].what); *target = (void*)rt_right[i]; break; }
    char b[512]; name_addr((uintptr_t)*target, b, sizeof b); lgv("hook %s\n", b);
    mp_build(); void *m = mp_get((uintptr_t)*target); char why[512];
    if (m && !abi_fixed && abi_mismatch(m, why, sizeof why)) {
      lg("SKIP hook %s::%s (SysV struct ABI not supported by Il2CppInterop trampoline): %s\n",
         il.class_get_name(il.method_get_class(m)), il.method_get_name(m), why);
      return; } }
  real_hook_attach(target, detour); }

// MelonLoader dlopen()s bare "GameAssembly.dylib"; dyld only searches DYLD_LIBRARY_PATH (the game root) for that.
static void *w_dlopen(const char *path, int mode) {
  if (path && !strchr(path, '/') && !strcmp(path, "GameAssembly.dylib")) {
    for (uint32_t k = 0; k < _dyld_image_count(); k++) { const char *in = _dyld_get_image_name(k);
      if (in && strstr(in, "/Contents/Frameworks/GameAssembly.dylib")) { lgv("dlopen %s -> %s\n", path, in); return dlopen(in, mode); } } }
  return dlopen(path, mode); }

void* fix_dlsym(void *h, const char *n) {
  if (n && !strcmp(n, "dlsym")) return (void*)fix_dlsym;      // managed P/Invoke of dlsym comes back through us
  if (n && !strcmp(n, "dlopen")) return (void*)w_dlopen;
  if (n && !strcmp(n, "NativeHookAttach")) { void *r = dlsym(h, n); if (!r) return r; real_hook_attach = (hook_fn)r; return (void*)w_hook_attach; }
  if (n && n[0] == '_' && !strncmp(n, "_dyld_get_image_", 16)) {
    if (!strcmp(n, "_dyld_get_image_name")) return (void*)w_image_name;
    if (!strcmp(n, "_dyld_get_image_header")) return (void*)w_image_header;
    if (!strcmp(n, "_dyld_get_image_vmaddr_slide")) return (void*)w_image_slide;
  }
  uintptr_t ra = (uintptr_t)__builtin_return_address(0);
  if (n && ra >= up_lo && ra < up_hi) {
    pthread_mutex_lock(&mu);
    if (!searched && !strncmp(n, "il2cpp_", 7)) find_detour();
    dlsym_fn d = detour;
    pthread_mutex_unlock(&mu);
    if (d) { void *r = d(h, n);
      if (!strcmp(n,"il2cpp_init") || !strcmp(n,"il2cpp_runtime_invoke")) lgv("routed %s -> %p\n", n, r);
      return r; }
  }
  return dlsym(h, n);
}


// Redirect managed (.NET) reads of the universal GameAssembly.dylib to the thinned x86_64 copy that Cpp2IL used,
// so Il2CppInterop's file offsets line up.
static char thin_path[2048] = {0};
static int is_ga_path(const char *p) { size_t n = p ? strlen(p) : 0; const char *suf = "/Contents/Frameworks/GameAssembly.dylib";
  size_t m = strlen(suf); return n > m && !strcmp(p + n - m, suf); }
static int from_dotnet(const void *ra) { Dl_info i; return ra && dladdr(ra, &i) && i.dli_fname &&
  (strstr(i.dli_fname, "libSystem.Native") || strstr(i.dli_fname, "libcoreclr") || strstr(i.dli_fname, "/dotnet/")); }
int fix_open(const char *path, int flags, ...) {
  int mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
  if (thin_path[0] && (flags & O_ACCMODE) == O_RDONLY && is_ga_path(path) && from_dotnet(__builtin_return_address(0))
      && access(thin_path, R_OK) == 0) {
    lgv("open redirect %s -> thin\n", path); return open(thin_path, flags, mode); }
  return open(path, flags, mode);
}

// Crash diagnostics: name a code address (nearest symbol, including GameAssembly's local ones).
#include <signal.h>
#include <sys/ucontext.h>
static void name_addr(uintptr_t a, char *out, size_t n) {
  Dl_info i; const char *img = "?", *sym = NULL; uintptr_t base = 0, sa = 0;
  if (dladdr((void*)a, &i)) { img = i.dli_fname ? (strrchr(i.dli_fname, '/') ? strrchr(i.dli_fname, '/') + 1 : i.dli_fname) : "?";
    base = (uintptr_t)i.dli_fbase; sym = i.dli_sname; sa = (uintptr_t)i.dli_saddr; }
  if (base && strstr(img, "GameAssembly")) {   // dladdr only knows exported symbols; walk the full symtab
    for (uint32_t k = 0; k < _dyld_image_count(); k++) { const char *in = _dyld_get_image_name(k);
      if (!in || !strstr(in, "/GameAssembly.dylib")) continue;
      const struct mach_header_64 *mh = (const void*)_dyld_get_image_header(k); intptr_t slide = _dyld_get_image_vmaddr_slide(k);
      const struct symtab_command *st = NULL; const struct segment_command_64 *le = NULL; const uint8_t *p = (const uint8_t*)(mh + 1);
      for (uint32_t c = 0; c < mh->ncmds; c++) { const struct load_command *lc = (const void*)p;
        if (lc->cmd == LC_SYMTAB) st = (const void*)p;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64*)p)->segname, "__LINKEDIT")) le = (const void*)p;
        p += lc->cmdsize; }
      if (st && le) { uintptr_t lb = le->vmaddr + slide - le->fileoff; const struct nlist_64 *sy = (const void*)(lb + st->symoff);
        const char *strs = (const char*)(lb + st->stroff);
        for (uint32_t j = 0; j < st->nsyms; j++) { if ((sy[j].n_type & N_TYPE) != N_SECT || (sy[j].n_type & N_STAB)) continue;
          uintptr_t v = sy[j].n_value + slide; if (v <= a && v > sa) { sa = v; sym = strs + sy[j].n_un.n_strx; } } }
      break; } }
  snprintf(out, n, "%p %s!%s+0x%lx (img+0x%lx)", (void*)a, img, sym ? sym : "?", (unsigned long)(a - sa), (unsigned long)(a - base)); }
static const int crash_sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP };
#define NSIG_CRASH 6
static struct sigaction old_sa[NSIG_CRASH];
// A managed helper (MelonMacFixes plugin) can register a callback that logs the managed stack on a native crash.
// Only safe when the faulting thread is in preemptive mode (inside a P/Invoke), which is the usual case for faults
// in GameAssembly called from managed code. Worth the risk: we are crashing anyway.
static void (*managed_crash_cb)(void) = NULL;
__attribute__((visibility("default"))) void melonfix_set_crash_callback(void (*cb)(void)) { managed_crash_cb = cb; lg("managed crash callback registered\n"); }
static void on_crash(int sig, siginfo_t *si, void *uc_) {
  ucontext_t *uc = uc_; char b[512];
  uintptr_t pc = uc->uc_mcontext->__ss.__rip, fp = uc->uc_mcontext->__ss.__rbp;
  lg("=== signal %d at addr %p\n", sig, si->si_addr);
  name_addr(pc, b, sizeof b); lg("  pc %s\n", b);
  lg("  rdi=%p rsi=%p rdx=%p rcx=%p rax=%p\n", (void*)uc->uc_mcontext->__ss.__rdi, (void*)uc->uc_mcontext->__ss.__rsi,
     (void*)uc->uc_mcontext->__ss.__rdx, (void*)uc->uc_mcontext->__ss.__rcx, (void*)uc->uc_mcontext->__ss.__rax);
  { uintptr_t *sp = (uintptr_t*)uc->uc_mcontext->__ss.__rsp; name_addr(sp[0], b, sizeof b); lg("  [rsp] %s\n", b); }
  lg("  thread %p\n", (void*)pthread_self());
  for (int d = 0; d < 24 && fp && !(fp & 7); d++) { uintptr_t ra = ((uintptr_t*)fp)[1]; if (!ra) break;
    name_addr(ra, b, sizeof b); lg("  #%d %s\n", d, b); fp = ((uintptr_t*)fp)[0]; }
  static int in_cb = 0;
  if (managed_crash_cb && !in_cb) { in_cb = 1; lg("  managed stack (via MelonMacFixes):\n"); managed_crash_cb(); }
  struct sigaction *o = &old_sa[0]; for (int i = 0; i < NSIG_CRASH; i++) if (crash_sigs[i] == sig) o = &old_sa[i];
  if (o->sa_flags & SA_SIGINFO && o->sa_sigaction) { o->sa_sigaction(sig, si, uc_); return; }
  if (o->sa_handler != SIG_DFL && o->sa_handler != SIG_IGN && o->sa_handler) { o->sa_handler(sig); return; }
  signal(sig, SIG_DFL); }
static void install_crash_log(void) { struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_sigaction = on_crash;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK; struct sigaction cur;
  for (int i = 0; i < NSIG_CRASH; i++) { sigaction(crash_sigs[i], NULL, &cur);
    if (cur.sa_sigaction != on_crash) sigaction(crash_sigs[i], &sa, &old_sa[i]); } }
// CoreCLR and Unity install their own handlers later without chaining back; keep ours on top, chaining to theirs.
static void *crash_keeper(void *x) { (void)x; for (int i = 0; i < 300; i++) { sleep(1); install_crash_log(); } return NULL; }

// Cpp2IL can't read a slice of a universal Mach-O, so MelonLoader's Cpp2IL runs through our wrapper script, which
// thins GameAssembly and passes explicit paths. Redirecting at exec time (instead of replacing MelonLoader's Cpp2IL
// file) means a fresh Cpp2IL download by MelonLoader keeps working.
#include <spawn.h>
static char wrapper_path[2048] = {0};
static const char *const CPP2IL_SUFFIX = "/Il2CppAssemblyGenerator/Cpp2IL/Cpp2IL";
static int is_cpp2il(const char *p) { size_t n = p ? strlen(p) : 0, m = strlen(CPP2IL_SUFFIX);
  return n > m && !strcmp(p + n - m, CPP2IL_SUFFIX); }
// Builds {"/bin/bash", wrapper, "--real", path, argv[1..], NULL} in buf (no malloc: may run in a forked child).
static char *const *wrap_argv(const char *path, char *const argv[], char **buf, size_t cap) {
  size_t k = 0; buf[k++] = "/bin/bash"; buf[k++] = wrapper_path; buf[k++] = "--real"; buf[k++] = (char*)path;
  for (size_t i = 1; argv && argv[i] && k + 1 < cap; i++) buf[k++] = argv[i];
  buf[k] = NULL; return buf; }
int fix_execve(const char *path, char *const argv[], char *const envp[]) {
  if (wrapper_path[0] && is_cpp2il(path) && access(wrapper_path, R_OK) == 0) {
    static char *buf[512]; return execve("/bin/bash", wrap_argv(path, argv, buf, 512), envp); }
  return execve(path, argv, envp); }
int fix_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at,
                    char *const argv[], char *const envp[]) {
  if (wrapper_path[0] && is_cpp2il(path) && access(wrapper_path, R_OK) == 0) {
    char *buf[512]; lg("cpp2il -> wrapper (posix_spawn)\n"); return posix_spawn(pid, "/bin/bash", fa, at, wrap_argv(path, argv, buf, 512), envp); }
  return posix_spawn(pid, path, fa, at, argv, envp); }

__attribute__((used)) static struct { const void *r; const void *o; } interposers[]
  __attribute__((section("__DATA,__interpose"))) = {
    { (const void*)fix_dlsym, (const void*)dlsym }, { (const void*)fix_open, (const void*)open },
    { (const void*)fix_execve, (const void*)execve }, { (const void*)fix_posix_spawn, (const void*)posix_spawn } };

__attribute__((constructor)) static void init(void) {
  // Only act inside the game itself; child tools (Cpp2IL etc.) must run clean.
  const char *self = _dyld_get_image_name(0); int is_game = 0;
  for (uint32_t k = 0; k < _dyld_image_count(); k++) { const struct mach_header *h = _dyld_get_image_header(k);
    if (h && h->filetype == MH_EXECUTE) { const char *n = _dyld_get_image_name(k); is_game = n && strstr(n, "/BloonsTD6.app/Contents/MacOS/") != NULL; break; } }
  (void)self;
  // Stop child processes from inheriting the injection (dyld has already read these for this process).
  setenv("DYLD_INSERT_LIBRARIES", "", 1);
  if (!is_game) return;
  { const char *e = getenv("MELONFIX_DEBUG"); dbg = e && *e && *e != '0'; }
  lg("melonfix v13 loaded%s\n", dbg ? " (debug)" : "");
  { const char *d = getenv("MELONFIX_DIR"); if (d) snprintf(thin_path, sizeof thin_path,
      "%s/_modkit/cache/GameAssembly.x86_64.dylib", d);
    if (d) snprintf(wrapper_path, sizeof wrapper_path, "%s/_modkit/cpp2il-wrapper.sh", d); }
  snapshot_unityplayer();
  if (dbg) { install_crash_log(); pthread_t t; pthread_create(&t, NULL, crash_keeper, NULL); pthread_detach(t); }
}
