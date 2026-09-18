// BNNSCompat-v4.c
// Experimental Logic Pro 11.2.2 / macOS 27 BNNS compatibility adapter
// v4.0-alpha4
//
// alpha4 keeps the modern GraphContext backend from alpha3, but fixes the
// execute bridge in two important ways:
//   1. Logic's legacy output+input pointer array is mapped to the modern BNNS
//      argument positions by argument name instead of assuming identical order.
//   2. Execution uses BNNSGraphArgumentTypeTensor and BNNSTensor descriptors
//      obtained from BNNSGraphContextGetTensor. This preserves the current
//      BNNS tensor shape/stride metadata instead of forcing raw-pointer mode.
//
// A small shadow-buffer fallback is used only when a known malloc-backed
// legacy allocation is smaller than the modern tensor allocation requirement,
// or when an argument pointer is NULL. This prevents the modern backend from
// being handed an undersized allocation while preserving direct zero-copy
// access for normal external audio/conditioning buffers.

#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <stdarg.h>
#include <unistd.h>

#ifdef __APPLE__
#include <malloc/malloc.h>
#endif

// Pull the exact current SDK layouts for BNNSTensor and
// bnns_graph_argument_t without letting the modern C declarations conflict
// with the legacy symbol names exported below.
#if defined(__APPLE__) && __has_include(<Accelerate/Accelerate.h>)
#define BNNSGraphCompileFromFile BNNSGraphCompileFromFile_modern_decl
#define BNNSGraphExecute BNNSGraphExecute_modern_decl
#define BNNSGraphGetInputNames BNNSGraphGetInputNames_modern_decl
#define BNNSGraphGetOutputNames BNNSGraphGetOutputNames_modern_decl
#define BNNSGraphGetTensorDescriptor BNNSGraphGetTensorDescriptor_modern_decl
#define BNNSGraphGetArgumentPosition BNNSGraphGetArgumentPosition_modern_decl
#include <Accelerate/Accelerate.h>
#undef BNNSGraphCompileFromFile
#undef BNNSGraphExecute
#undef BNNSGraphGetInputNames
#undef BNNSGraphGetOutputNames
#undef BNNSGraphGetTensorDescriptor
#undef BNNSGraphGetArgumentPosition
#else
// Non-Apple fallbacks are only for source syntax checking in the release
// build environment. The patcher itself only runs on macOS.
typedef struct { void *data; size_t size; } bnns_graph_t;
typedef struct { void *data; size_t size; } bnns_graph_context_t;
typedef struct { void *data; size_t size; } bnns_graph_compile_options_t;
typedef struct {
    void *data;
    size_t data_size_in_bytes;
    unsigned char opaque[240];
} BNNSTensor;
typedef struct {
    union { BNNSTensor *tensor; void *descriptor; void *data_ptr; };
    size_t data_ptr_size;
} bnns_graph_argument_t;
typedef uint32_t BNNSGraphArgumentType;
enum {
    BNNSGraphArgumentTypePointer = 0,
    BNNSGraphArgumentTypeTensor = 2,
};
#endif

#define EXPORT __attribute__((visibility("default")))
#define MAX_GRAPHS 512
#define MAX_ARGUMENTS 256
#define LEGACY_OPTIONS_MAGIC UINT64_C(0x424e4e534f505434) /* "BNNSOPT4" */
#define ARG_INTENT_IN 1u
#define ARG_INTENT_OUT 2u
#define ARG_INTENT_INOUT 3u
#define MESSAGE_MASK_ALL 0x0fu

// Modern BNNS entry points. All are looked up dynamically so the adapter has
// no hard dependency on private/versioned implementation names at load time.
typedef bnns_graph_t (*fn_compile_v2_t)(const char *, const char *, bnns_graph_compile_options_t);
typedef bnns_graph_compile_options_t (*fn_options_default_t)(void);
typedef void (*fn_options_single_thread_t)(bnns_graph_compile_options_t, bool);
typedef void (*fn_options_predefined_t)(bnns_graph_compile_options_t, uint32_t);
typedef size_t (*fn_input_count_t)(bnns_graph_t, const char *);
typedef int (*fn_input_names_v2_t)(bnns_graph_t, const char *, size_t, const char **);
typedef size_t (*fn_output_count_t)(bnns_graph_t, const char *);
typedef int (*fn_output_names_v2_t)(bnns_graph_t, const char *, size_t, const char **);
typedef size_t (*fn_argument_count_t)(bnns_graph_t, const char *);
typedef int (*fn_argument_intents_t)(bnns_graph_t, const char *, size_t, uint32_t *);
typedef int (*fn_tensor_descriptor_v2_t)(bnns_graph_t, const char *, const char *, bool, void *);
typedef size_t (*fn_argument_position_t)(bnns_graph_t, const char *, const char *);
typedef size_t (*fn_context_argument_position_t)(bnns_graph_context_t, const char *, const char *);

typedef bnns_graph_context_t (*fn_context_make_t)(bnns_graph_t);
typedef int (*fn_context_execute_t)(bnns_graph_context_t, const char *, size_t,
                                    bnns_graph_argument_t *, size_t, char *);
typedef size_t (*fn_context_workspace_t)(bnns_graph_context_t, const char *);
typedef int (*fn_context_get_tensor_t)(bnns_graph_context_t, const char *, const char *, bool, BNNSTensor *);
typedef size_t (*fn_tensor_alloc_size_t)(const BNNSTensor *);
typedef int (*fn_context_set_arg_type_t)(bnns_graph_context_t, BNNSGraphArgumentType);
typedef int (*fn_context_set_message_mask_t)(bnns_graph_context_t, uint32_t);

static void *g_accelerate;
static pthread_once_t g_resolve_once = PTHREAD_ONCE_INIT;

static fn_compile_v2_t p_compile_v2;
static fn_options_default_t p_options_default;
static fn_options_single_thread_t p_options_single_thread;
static fn_options_predefined_t p_options_predefined;
static fn_input_count_t p_input_count;
static fn_input_names_v2_t p_input_names_v2;
static fn_output_count_t p_output_count;
static fn_output_names_v2_t p_output_names_v2;
static fn_argument_count_t p_argument_count;
static fn_argument_intents_t p_argument_intents;
static fn_tensor_descriptor_v2_t p_tensor_descriptor_v2;
static fn_argument_position_t p_argument_position;
static fn_context_argument_position_t p_context_argument_position;
static fn_context_make_t p_context_make;
static fn_context_execute_t p_context_execute;
static fn_context_workspace_t p_context_workspace;
static fn_context_get_tensor_t p_context_get_tensor;
static fn_tensor_alloc_size_t p_tensor_alloc_size;
static fn_context_set_arg_type_t p_context_set_arg_type;
static fn_context_set_message_mask_t p_context_set_message_mask;

typedef struct {
    uint64_t magic;
    bnns_graph_compile_options_t modern;
} legacy_options_t;

typedef struct {
    _Atomic(void *) data; // published last
    size_t size;
    bnns_graph_context_t context;
    size_t workspace_size;

    // Logic 11.2.2 builds its legacy pointer vector as outputs followed by
    // inputs. legacy_to_modern translates that vector to the current API's
    // argument positions returned by BNNSGraphGetArgumentPosition().
    size_t legacy_argument_count;
    size_t *legacy_to_modern;

    // Arrays indexed by modern argument position.
    size_t *argument_sizes;
    uint32_t *argument_intents;
    BNNSTensor *tensor_templates;

    // Lazily allocated compatibility buffers, also indexed by modern position.
    void **shadow_buffers;
    size_t *shadow_sizes;

    _Atomic bool logged_first_execute;
    _Atomic bool logged_first_success;
    _Atomic bool logged_first_error;
    _Atomic bool logged_first_shadow;
} graph_record_t;

static graph_record_t g_graphs[MAX_GRAPHS];
static _Atomic size_t g_graph_count = 0;
static pthread_mutex_t g_graph_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_shadow_lock = PTHREAD_MUTEX_INITIALIZER;

static void log_message(const char *message) {
    FILE *f = fopen("/tmp/FCPBNNSCompat.log", "a");
    if (!f) return;
    time_t now = time(NULL);
    fprintf(f, "%lld %s\n", (long long)now, message);
    fclose(f);
}

static void log_format(const char *fmt, ...) {
    char buf[768];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    log_message(buf);
}

static void resolve_modern(void) {
    g_accelerate = dlopen("/System/Library/Frameworks/Accelerate.framework/Accelerate",
                         RTLD_LAZY | RTLD_LOCAL);
    if (!g_accelerate) {
        log_message("ERROR: could not dlopen Accelerate");
        return;
    }

#define RESOLVE(field, name) do { *(void **)(&(field)) = dlsym(g_accelerate, (name)); } while (0)
    RESOLVE(p_compile_v2, "BNNSGraphCompileFromFile_v2");
    RESOLVE(p_options_default, "BNNSGraphCompileOptionsMakeDefault");
    RESOLVE(p_options_single_thread, "BNNSGraphCompileOptionsSetTargetSingleThread");
    RESOLVE(p_options_predefined, "BNNSGraphCompileOptionsSetPredefinedOptimizations");
    RESOLVE(p_input_count, "BNNSGraphGetInputCount");
    RESOLVE(p_input_names_v2, "BNNSGraphGetInputNames_v2");
    RESOLVE(p_output_count, "BNNSGraphGetOutputCount");
    RESOLVE(p_output_names_v2, "BNNSGraphGetOutputNames_v2");
    RESOLVE(p_argument_count, "BNNSGraphGetArgumentCount");
    RESOLVE(p_argument_intents, "BNNSGraphGetArgumentIntents");
    RESOLVE(p_tensor_descriptor_v2, "BNNSGraphGetTensorDescriptor_v2");
    RESOLVE(p_argument_position, "BNNSGraphGetArgumentPosition");
    RESOLVE(p_context_argument_position, "BNNSGraphContextGetArgumentPosition");

    RESOLVE(p_context_make, "BNNSGraphContextMake");
    RESOLVE(p_context_execute, "BNNSGraphContextExecute_v2");
    RESOLVE(p_context_workspace, "BNNSGraphContextGetWorkspaceSize_v2");
    RESOLVE(p_context_get_tensor, "BNNSGraphContextGetTensor");
    RESOLVE(p_tensor_alloc_size, "BNNSTensorGetAllocationSize");
    RESOLVE(p_context_set_arg_type, "BNNSGraphContextSetArgumentType");
    RESOLVE(p_context_set_message_mask, "BNNSGraphContextSetMessageLogMask");
#undef RESOLVE

    if (!p_compile_v2 || !p_options_default || !p_options_single_thread ||
        !p_options_predefined || !p_input_count || !p_input_names_v2 ||
        !p_output_count || !p_output_names_v2 || !p_argument_count ||
        !p_argument_intents || !p_tensor_descriptor_v2 || !p_argument_position ||
        !p_context_make || !p_context_execute || !p_context_workspace ||
        !p_context_get_tensor || !p_tensor_alloc_size || !p_context_set_arg_type) {
        log_message("ERROR: one or more required modern BNNS symbols are missing");
    } else {
        log_message("adapter alpha4 loaded; Tensor GraphContext bridge resolved");
    }
}

static inline void ensure_resolved(void) {
    pthread_once(&g_resolve_once, resolve_modern);
}

static graph_record_t *record_from_legacy(void *legacy_graph) {
    if (!legacy_graph) return NULL;
    size_t count = atomic_load_explicit(&g_graph_count, memory_order_acquire);
    if (count > MAX_GRAPHS) count = MAX_GRAPHS;
    for (size_t i = 0; i < count; ++i) {
        void *p = atomic_load_explicit(&g_graphs[i].data, memory_order_acquire);
        if (p == legacy_graph) return &g_graphs[i];
    }
    return NULL;
}

static bnns_graph_t graph_from_legacy(void *legacy_graph) {
    graph_record_t *r = record_from_legacy(legacy_graph);
    if (r) return (bnns_graph_t){ r->data, r->size };

    bnns_graph_t graph = { legacy_graph, 0 };
#ifdef __APPLE__
    if (legacy_graph) {
        malloc_zone_t *zone = malloc_zone_from_ptr(legacy_graph);
        if (zone) graph.size = malloc_size(legacy_graph);
    }
#endif
    return graph;
}

static size_t safe_malloc_capacity(const void *ptr) {
#ifdef __APPLE__
    if (!ptr) return 0;
    malloc_zone_t *zone = malloc_zone_from_ptr(ptr);
    if (!zone) return 0;
    return malloc_size(ptr);
#else
    (void)ptr;
    return 0;
#endif
}

static bool fill_tensor_for_name(bnns_graph_context_t context,
                                 const char *name,
                                 BNNSTensor *tensor,
                                 size_t *allocation_size) {
    if (!name || !tensor || !allocation_size ||
        !p_context_get_tensor || !p_tensor_alloc_size) return false;
    memset(tensor, 0, sizeof(*tensor));
    if (p_context_get_tensor(context, NULL, name, true, tensor) != 0) return false;
    size_t size = p_tensor_alloc_size(tensor);
    if (size == SIZE_MAX) return false;
    *allocation_size = size;
    return true;
}

static void *ensure_shadow_buffer(graph_record_t *r, size_t modern_pos, size_t size) {
    if (!r || modern_pos >= r->legacy_argument_count || size == 0) return NULL;
    if (r->shadow_buffers[modern_pos] && r->shadow_sizes[modern_pos] >= size)
        return r->shadow_buffers[modern_pos];

    pthread_mutex_lock(&g_shadow_lock);
    if (!r->shadow_buffers[modern_pos] || r->shadow_sizes[modern_pos] < size) {
        void *p = NULL;
        size_t alignment = 64;
        if (posix_memalign(&p, alignment, size) != 0) p = NULL;
        if (p) {
            memset(p, 0, size);
            free(r->shadow_buffers[modern_pos]);
            r->shadow_buffers[modern_pos] = p;
            r->shadow_sizes[modern_pos] = size;
        }
    }
    void *result = r->shadow_buffers[modern_pos];
    pthread_mutex_unlock(&g_shadow_lock);
    return result;
}

static void free_graph_metadata(size_t *legacy_to_modern,
                                size_t *argument_sizes,
                                uint32_t *argument_intents,
                                BNNSTensor *tensor_templates,
                                void **shadow_buffers,
                                size_t *shadow_sizes,
                                size_t count) {
    if (shadow_buffers) {
        for (size_t i = 0; i < count; ++i) free(shadow_buffers[i]);
    }
    free(legacy_to_modern);
    free(argument_sizes);
    free(argument_intents);
    free(tensor_templates);
    free(shadow_buffers);
    free(shadow_sizes);
}

static bool build_graph_metadata(bnns_graph_t graph,
                                 bnns_graph_context_t context,
                                 size_t *out_legacy_count,
                                 size_t **out_legacy_to_modern,
                                 size_t **out_sizes,
                                 uint32_t **out_intents,
                                 BNNSTensor **out_tensors,
                                 void ***out_shadow_buffers,
                                 size_t **out_shadow_sizes) {
    size_t outputs = p_output_count(graph, NULL);
    size_t inputs = p_input_count(graph, NULL);
    size_t arg_count = p_argument_count(graph, NULL);

    if (outputs == SIZE_MAX || inputs == SIZE_MAX || arg_count == SIZE_MAX ||
        outputs > MAX_ARGUMENTS || inputs > MAX_ARGUMENTS ||
        outputs + inputs > MAX_ARGUMENTS || arg_count > MAX_ARGUMENTS ||
        outputs + inputs != arg_count || arg_count == 0) {
        log_format("ERROR: invalid argument counts outputs=%zu inputs=%zu total=%zu",
                   outputs, inputs, arg_count);
        return false;
    }

    size_t *legacy_to_modern = calloc(arg_count, sizeof(*legacy_to_modern));
    size_t *sizes = calloc(arg_count, sizeof(*sizes));
    uint32_t *intents = calloc(arg_count, sizeof(*intents));
    BNNSTensor *tensors = calloc(arg_count, sizeof(*tensors));
    void **shadow_buffers = calloc(arg_count, sizeof(*shadow_buffers));
    size_t *shadow_sizes = calloc(arg_count, sizeof(*shadow_sizes));
    bool *seen = calloc(arg_count, sizeof(*seen));
    size_t max_names = outputs > inputs ? outputs : inputs;
    const char **names = max_names ? calloc(max_names, sizeof(*names)) : NULL;

    if (!legacy_to_modern || !sizes || !intents || !tensors ||
        !shadow_buffers || !shadow_sizes || !seen || (max_names && !names)) {
        free(seen);
        free(names);
        free_graph_metadata(legacy_to_modern, sizes, intents, tensors,
                            shadow_buffers, shadow_sizes, arg_count);
        log_message("ERROR: could not allocate graph argument metadata");
        return false;
    }

    // Let the modern API tell us the definitive per-position intent.
    if (p_argument_intents(graph, NULL, arg_count, intents) != 0) {
        memset(intents, 0, arg_count * sizeof(*intents));
        log_message("WARNING: BNNSGraphGetArgumentIntents failed; using output/input fallback intents");
    }

    bool ok = true;
    size_t legacy_index = 0;

    // Logic 11.2.2's legacy metadata vector is output names first.
    if (outputs) {
        memset(names, 0, outputs * sizeof(*names));
        if (p_output_names_v2(graph, NULL, outputs, names) != 0) {
            ok = false;
        } else {
            for (size_t i = 0; i < outputs; ++i, ++legacy_index) {
                const char *name = names[i];
                size_t pos = name ? p_argument_position(graph, NULL, name) : SIZE_MAX;
                if (!name || pos >= arg_count || seen[pos]) {
                    ok = false;
                    break;
                }
                legacy_to_modern[legacy_index] = pos;
                seen[pos] = true;
                if (intents[pos] == 0) intents[pos] = ARG_INTENT_OUT;
                if (!fill_tensor_for_name(context, name, &tensors[pos], &sizes[pos])) {
                    ok = false;
                    break;
                }
            }
        }
    }

    // Then input names, exactly matching the legacy MAMachineLearning vector.
    if (ok && inputs) {
        memset(names, 0, inputs * sizeof(*names));
        if (p_input_names_v2(graph, NULL, inputs, names) != 0) {
            ok = false;
        } else {
            for (size_t i = 0; i < inputs; ++i, ++legacy_index) {
                const char *name = names[i];
                size_t pos = name ? p_argument_position(graph, NULL, name) : SIZE_MAX;
                if (!name || pos >= arg_count || seen[pos]) {
                    ok = false;
                    break;
                }
                legacy_to_modern[legacy_index] = pos;
                seen[pos] = true;
                if (intents[pos] == 0) intents[pos] = ARG_INTENT_IN;
                if (!fill_tensor_for_name(context, name, &tensors[pos], &sizes[pos])) {
                    ok = false;
                    break;
                }
            }
        }
    }

    if (ok) {
        for (size_t i = 0; i < arg_count; ++i) {
            if (!seen[i]) {
                ok = false;
                break;
            }
        }
    }

    free(seen);
    free(names);

    if (!ok) {
        free_graph_metadata(legacy_to_modern, sizes, intents, tensors,
                            shadow_buffers, shadow_sizes, arg_count);
        log_message("ERROR: could not build a complete legacy-to-modern argument map");
        return false;
    }

    *out_legacy_count = arg_count;
    *out_legacy_to_modern = legacy_to_modern;
    *out_sizes = sizes;
    *out_intents = intents;
    *out_tensors = tensors;
    *out_shadow_buffers = shadow_buffers;
    *out_shadow_sizes = shadow_sizes;
    return true;
}

static void register_graph(bnns_graph_t graph) {
    if (!graph.data || graph.size == 0) return;

    bnns_graph_context_t context = {0};
    size_t workspace_size = 0;
    size_t legacy_argument_count = 0;
    size_t *legacy_to_modern = NULL;
    size_t *argument_sizes = NULL;
    uint32_t *argument_intents = NULL;
    BNNSTensor *tensor_templates = NULL;
    void **shadow_buffers = NULL;
    size_t *shadow_sizes = NULL;

    if (p_context_make) context = p_context_make(graph);
    if (!context.data || context.size == 0) {
        log_message("ERROR: BNNSGraphContextMake returned an empty context");
        return;
    }

    // Tensor mode is deliberate. The current SDK explicitly requires tensor
    // arguments for graph arguments with dynamic strides. Pointer mode used by
    // alpha3 discarded that shape/stride metadata and triggered a BNNS trap.
    if (p_context_set_arg_type) {
        int rc = p_context_set_arg_type(context, BNNSGraphArgumentTypeTensor);
        if (rc != 0) {
            log_format("ERROR: BNNSGraphContextSetArgumentType(Tensor) returned %d", rc);
            return;
        }
    }

    if (p_context_set_message_mask) {
        (void)p_context_set_message_mask(context, MESSAGE_MASK_ALL);
    }

    if (p_context_workspace) {
        workspace_size = p_context_workspace(context, NULL);
        if (workspace_size == SIZE_MAX) {
            log_message("ERROR: BNNSGraphContextGetWorkspaceSize reported SIZE_MAX");
            return;
        }
    }

    if (!build_graph_metadata(graph, context,
                              &legacy_argument_count,
                              &legacy_to_modern,
                              &argument_sizes,
                              &argument_intents,
                              &tensor_templates,
                              &shadow_buffers,
                              &shadow_sizes)) {
        return;
    }

    pthread_mutex_lock(&g_graph_lock);
    size_t count = atomic_load_explicit(&g_graph_count, memory_order_relaxed);
    for (size_t i = 0; i < count; ++i) {
        void *p = atomic_load_explicit(&g_graphs[i].data, memory_order_acquire);
        if (p == graph.data) {
            g_graphs[i].size = graph.size;
            pthread_mutex_unlock(&g_graph_lock);
            free_graph_metadata(legacy_to_modern, argument_sizes, argument_intents,
                                tensor_templates, shadow_buffers, shadow_sizes,
                                legacy_argument_count);
            return;
        }
    }

    if (count < MAX_GRAPHS) {
        graph_record_t *r = &g_graphs[count];
        r->size = graph.size;
        r->context = context;
        r->workspace_size = workspace_size;
        r->legacy_argument_count = legacy_argument_count;
        r->legacy_to_modern = legacy_to_modern;
        r->argument_sizes = argument_sizes;
        r->argument_intents = argument_intents;
        r->tensor_templates = tensor_templates;
        r->shadow_buffers = shadow_buffers;
        r->shadow_sizes = shadow_sizes;
        atomic_store_explicit(&r->logged_first_execute, false, memory_order_relaxed);
        atomic_store_explicit(&r->logged_first_success, false, memory_order_relaxed);
        atomic_store_explicit(&r->logged_first_error, false, memory_order_relaxed);
        atomic_store_explicit(&r->logged_first_shadow, false, memory_order_relaxed);
        atomic_store_explicit(&r->data, graph.data, memory_order_release);
        atomic_store_explicit(&g_graph_count, count + 1, memory_order_release);
        log_format("registered Tensor BNNS graph context: args=%zu workspace=%zu",
                   legacy_argument_count, workspace_size);
    } else {
        free_graph_metadata(legacy_to_modern, argument_sizes, argument_intents,
                            tensor_templates, shadow_buffers, shadow_sizes,
                            legacy_argument_count);
        log_message("WARNING: graph registry is full");
    }
    pthread_mutex_unlock(&g_graph_lock);
}

static legacy_options_t *legacy_options_from_ptr(void *opaque) {
    legacy_options_t *options = (legacy_options_t *)opaque;
    if (!options || options->magic != LEGACY_OPTIONS_MAGIC) return NULL;
    return options;
}

static size_t bounded_copy_size(const void *legacy_ptr, size_t expected_size) {
    if (!legacy_ptr || expected_size == 0) return 0;
    size_t capacity = safe_malloc_capacity(legacy_ptr);
    if (capacity > 0 && capacity < expected_size) return capacity;
    return expected_size;
}

static void prepare_shadow_input(void *shadow,
                                 size_t expected_size,
                                 const void *legacy_ptr,
                                 size_t copy_size) {
    if (!shadow || expected_size == 0) return;
    memset(shadow, 0, expected_size);
    if (legacy_ptr && copy_size) memcpy(shadow, legacy_ptr, copy_size);
}

// ----- Old Logic-facing BNNS SPI ---------------------------------------------

EXPORT void *BNNSGraphOptionsCreateDefault(void) {
    ensure_resolved();
    if (!p_options_default) return NULL;
    bnns_graph_compile_options_t modern = p_options_default();
    if (!modern.data || modern.size == 0) {
        log_message("ERROR: BNNSGraphCompileOptionsMakeDefault returned empty options");
        return NULL;
    }
    legacy_options_t *legacy = calloc(1, sizeof(*legacy));
    if (!legacy) return NULL;
    legacy->magic = LEGACY_OPTIONS_MAGIC;
    legacy->modern = modern;
    return legacy;
}

EXPORT void BNNSGraphOptionsSetSingleThread(void *opaque_options, bool enabled) {
    ensure_resolved();
    legacy_options_t *options = legacy_options_from_ptr(opaque_options);
    if (p_options_single_thread && options)
        p_options_single_thread(options->modern, enabled);
}

EXPORT void BNNSGraphOptionsSetPredefinedOptimizations(void *opaque_options, uint32_t flags) {
    ensure_resolved();
    legacy_options_t *options = legacy_options_from_ptr(opaque_options);
    if (p_options_predefined && options)
        p_options_predefined(options->modern, flags);
}

EXPORT void *BNNSGraphCompileFromFile(uint64_t legacy_selector,
                                      const char *filename,
                                      const char *function,
                                      void *opaque_options) {
    (void)legacy_selector;
    ensure_resolved();
    if (!p_compile_v2 || !filename) return NULL;

    bnns_graph_compile_options_t options = {0};
    legacy_options_t *legacy = legacy_options_from_ptr(opaque_options);
    if (legacy) options = legacy->modern;

    bnns_graph_t graph = p_compile_v2(filename, function, options);
    if (graph.data && graph.size) {
        register_graph(graph);
    } else {
        log_message("ERROR: BNNSGraphCompileFromFile_v2 returned an empty graph");
    }
    return graph.data;
}

EXPORT int BNNSGraphExecute(void *legacy_graph, void **legacy_arguments, void *legacy_workspace) {
    ensure_resolved();
    graph_record_t *r = record_from_legacy(legacy_graph);
    if (!r || !r->context.data || !p_context_execute || !legacy_arguments ||
        r->legacy_argument_count == 0 || r->legacy_argument_count > MAX_ARGUMENTS ||
        !r->legacy_to_modern || !r->argument_sizes || !r->argument_intents ||
        !r->tensor_templates) {
        log_message("ERROR: Tensor GraphContext execute bridge missing graph metadata");
        return -1;
    }

    bnns_graph_argument_t args[MAX_ARGUMENTS];
    memset(args, 0, r->legacy_argument_count * sizeof(args[0]));

    size_t null_count = 0;
    size_t shadow_count = 0;
    size_t undersized_count = 0;

    // First bind every legacy pointer to its modern named position.
    for (size_t legacy_pos = 0; legacy_pos < r->legacy_argument_count; ++legacy_pos) {
        size_t modern_pos = r->legacy_to_modern[legacy_pos];
        if (modern_pos >= r->legacy_argument_count) {
            log_message("ERROR: corrupt legacy-to-modern argument map");
            return -1;
        }

        void *legacy_ptr = legacy_arguments[legacy_pos];
        size_t expected_size = r->argument_sizes[modern_pos];
        uint32_t intent = r->argument_intents[modern_pos];
        size_t known_capacity = safe_malloc_capacity(legacy_ptr);
        bool undersized = legacy_ptr && known_capacity > 0 && known_capacity < expected_size;
        bool need_shadow = (legacy_ptr == NULL && expected_size > 0) || undersized;
        void *bound_ptr = legacy_ptr;

        if (!legacy_ptr) ++null_count;
        if (undersized) ++undersized_count;

        if (need_shadow) {
            void *shadow = ensure_shadow_buffer(r, modern_pos, expected_size);
            if (!shadow) {
                log_format("ERROR: could not allocate shadow tensor arg=%zu bytes=%zu",
                           modern_pos, expected_size);
                return -1;
            }
            ++shadow_count;
            bound_ptr = shadow;

            if (intent == ARG_INTENT_IN || intent == ARG_INTENT_INOUT || intent == 0) {
                size_t copy_size = bounded_copy_size(legacy_ptr, expected_size);
                prepare_shadow_input(shadow, expected_size, legacy_ptr, copy_size);
            }
        }

        BNNSTensor *tensor = &r->tensor_templates[modern_pos];
        tensor->data = bound_ptr;
        tensor->data_size_in_bytes = expected_size;
        args[modern_pos].tensor = tensor;
    }

    bool expected = false;
    if (atomic_compare_exchange_strong(&r->logged_first_execute, &expected, true)) {
        size_t ws_capacity = safe_malloc_capacity(legacy_workspace);
        long page_size = sysconf(_SC_PAGESIZE);
        bool ws_aligned = !legacy_workspace || page_size <= 0 ||
                          ((uintptr_t)legacy_workspace % (uintptr_t)page_size) == 0;
        log_format("entering first Tensor GraphContextExecute: args=%zu workspace=%zu ws_capacity=%zu aligned=%d null=%zu shadow=%zu undersized=%zu",
                   r->legacy_argument_count, r->workspace_size, ws_capacity,
                   ws_aligned ? 1 : 0, null_count, shadow_count, undersized_count);
    }

    if (shadow_count) {
        expected = false;
        if (atomic_compare_exchange_strong(&r->logged_first_shadow, &expected, true))
            log_format("compatibility shadow buffers active: count=%zu undersized=%zu null=%zu",
                       shadow_count, undersized_count, null_count);
    }

    size_t workspace_size = legacy_workspace ? r->workspace_size : 0;
    char *workspace = legacy_workspace ? (char *)legacy_workspace : NULL;

    // If Logic's legacy workspace is provably too small or misaligned for the
    // modern context, letting BNNS allocate its own workspace is safer than
    // claiming an invalid buffer. This is only a fallback path.
    if (workspace) {
        size_t ws_capacity = safe_malloc_capacity(workspace);
        long page_size = sysconf(_SC_PAGESIZE);
        bool aligned = page_size <= 0 ||
                       ((uintptr_t)workspace % (uintptr_t)page_size) == 0;
        if (!aligned || (ws_capacity > 0 && ws_capacity < workspace_size)) {
            workspace = NULL;
            workspace_size = 0;
        }
    }

    int rc = p_context_execute(r->context, NULL, r->legacy_argument_count, args,
                               workspace_size, workspace);

    // Copy shadowed outputs/state back into Logic's legacy buffers. For a
    // known undersized malloc allocation, never write beyond its real capacity.
    for (size_t legacy_pos = 0; legacy_pos < r->legacy_argument_count; ++legacy_pos) {
        size_t modern_pos = r->legacy_to_modern[legacy_pos];
        void *shadow = r->shadow_buffers ? r->shadow_buffers[modern_pos] : NULL;
        void *legacy_ptr = legacy_arguments[legacy_pos];
        if (!shadow || !legacy_ptr) continue;

        size_t expected_size = r->argument_sizes[modern_pos];
        size_t known_capacity = safe_malloc_capacity(legacy_ptr);
        bool was_undersized = known_capacity > 0 && known_capacity < expected_size;
        if (!was_undersized) continue;

        uint32_t intent = r->argument_intents[modern_pos];
        if (intent == ARG_INTENT_OUT || intent == ARG_INTENT_INOUT || intent == 0) {
            memcpy(legacy_ptr, shadow, known_capacity);
        }
    }

    if (rc != 0) {
        expected = false;
        if (atomic_compare_exchange_strong(&r->logged_first_error, &expected, true))
            log_format("ERROR: first BNNSGraphContextExecute_v2 failure rc=%d", rc);
    } else {
        expected = false;
        if (atomic_compare_exchange_strong(&r->logged_first_success, &expected, true))
            log_message("first Tensor BNNSGraphContextExecute_v2 call succeeded");
    }
    return rc;
}

EXPORT size_t BNNSGraphGetWorkspaceSize(void *legacy_graph) {
    ensure_resolved();
    graph_record_t *r = record_from_legacy(legacy_graph);
    if (!r || !r->context.data) return 0;
    return r->workspace_size;
}

EXPORT size_t BNNSGraphGetSize(void *legacy_graph) {
    return graph_from_legacy(legacy_graph).size;
}

EXPORT size_t BNNSGraphGetNumInputs(void *legacy_graph, const char *function) {
    ensure_resolved();
    if (!p_input_count) return 0;
    bnns_graph_t graph = graph_from_legacy(legacy_graph);
    if (!graph.data || graph.size == 0) return 0;
    return p_input_count(graph, function);
}

EXPORT int BNNSGraphGetInputNames(void *legacy_graph, const char *function,
                                  size_t count, const char **names) {
    ensure_resolved();
    if (!p_input_names_v2) return -1;
    bnns_graph_t graph = graph_from_legacy(legacy_graph);
    if (!graph.data || graph.size == 0) return -1;
    return p_input_names_v2(graph, function, count, names);
}

EXPORT size_t BNNSGraphGetNumOutputs(void *legacy_graph, const char *function) {
    ensure_resolved();
    if (!p_output_count) return 0;
    bnns_graph_t graph = graph_from_legacy(legacy_graph);
    if (!graph.data || graph.size == 0) return 0;
    return p_output_count(graph, function);
}

EXPORT int BNNSGraphGetOutputNames(void *legacy_graph, const char *function,
                                   size_t count, const char **names) {
    ensure_resolved();
    if (!p_output_names_v2) return -1;
    bnns_graph_t graph = graph_from_legacy(legacy_graph);
    if (!graph.data || graph.size == 0) return -1;
    return p_output_names_v2(graph, function, count, names);
}

EXPORT int BNNSGraphGetTensorDescriptor(void *legacy_graph, const char *function,
                                        const char *argument,
                                        bool fill_known_dynamic_shapes,
                                        void *descriptor) {
    ensure_resolved();
    if (!p_tensor_descriptor_v2) return -1;
    bnns_graph_t graph = graph_from_legacy(legacy_graph);
    if (!graph.data || graph.size == 0) return -1;
    return p_tensor_descriptor_v2(graph, function, argument,
                                  fill_known_dynamic_shapes, descriptor);
}

EXPORT size_t BNNSGraphGetArgumentPosition(void *legacy_graph,
                                           const char *function,
                                           const char *argument) {
    ensure_resolved();
    if (!p_argument_position) return SIZE_MAX;
    bnns_graph_t graph = graph_from_legacy(legacy_graph);
    if (!graph.data || graph.size == 0) return SIZE_MAX;
    return p_argument_position(graph, function, argument);
}

EXPORT size_t BNNSGraphContextGetArgPosition(void *legacy_context,
                                             const char *function,
                                             const char *argument) {
    ensure_resolved();
    if (!p_context_argument_position || !legacy_context) return SIZE_MAX;
    bnns_graph_context_t context = { legacy_context, 0 };
#ifdef __APPLE__
    malloc_zone_t *zone = malloc_zone_from_ptr(legacy_context);
    if (zone) context.size = malloc_size(legacy_context);
#endif
    if (context.size == 0) return SIZE_MAX;
    return p_context_argument_position(context, function, argument);
}
