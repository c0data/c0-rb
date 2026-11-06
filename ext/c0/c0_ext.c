/* Ruby C extension: a thin binding over the c0 single-header C core (1.0).
 *
 * Two layers live here:
 *
 *   C0::Ext      module functions that walk a Ruby String with the c0.h
 *                navigators and hand back byte offsets, so the Ruby layer can
 *                return shared (zero-copy) byteslices into the caller's buffer.
 *                Every range is bounds-checked against the string as it is
 *                now, so a mutated buffer can never make us read out of range.
 *
 *   C0::Builder  a TypedData object owning a c0_builder (init/free pair), with
 *                the whole writer API: the primitives (one method per code,
 *                fs gs rs us sub soh dle can bel enq syn eot etb em) and the
 *                composed methods built on them, block forms included.
 *
 * Errors become exceptions deriving from C0::Error, with the byte position on
 * the syntax errors. Malloc'd results from c0.h (pretty form) are copied into
 * Ruby strings and freed before returning.
 */
#include "ruby.h"
#include "ruby/encoding.h"

#define C0_IMPLEMENTATION
#include "c0.h"

static VALUE mC0, mExt, mPretty, cBuilder;
static VALUE eError, eSyntaxError, eUnassignedCodeError, eUnexpectedEndError, eKeyError, eBuildError,
    eGlyphInDataError;

/* ---- buffers and ranges -------------------------------------------------- */

typedef struct {
    VALUE str;
    const uint8_t *p;
    size_t len;
} buf_t;

static buf_t get_buf(VALUE str) {
    buf_t b;
    StringValue(str);
    b.str = str;
    b.p = (const uint8_t *)RSTRING_PTR(str);
    b.len = (size_t)RSTRING_LEN(str);
    return b;
}

/* [s, e) must lie inside the buffer. */
static void check_range(buf_t b, long s, long e) {
    if (s < 0 || e < s || (size_t)e > b.len) {
        rb_raise(rb_eRangeError, "byte range %ld...%ld is outside the buffer (%ld bytes)", s, e, (long)b.len);
    }
}

static c0_bytes slice_of(buf_t b, VALUE vs, VALUE ve) {
    long s = NUM2LONG(vs), e = NUM2LONG(ve);
    check_range(b, s, e);
    return c0_bytes_of(b.p + s, (size_t)(e - s));
}

/* A [start, end] pair for a c0_bytes slice of the buffer. */
static VALUE span(buf_t b, c0_bytes x) {
    long s = (long)(x.ptr - b.p);
    return rb_ary_new3(2, LONG2NUM(s), LONG2NUM(s + (long)x.len));
}

/* A shared byteslice of the buffer (zero-copy for long strings). */
static VALUE substr(buf_t b, const uint8_t *ptr, size_t len) {
    VALUE s = rb_str_substr(b.str, (long)(ptr - b.p), (long)len);
    return rb_enc_associate(s, rb_ascii8bit_encoding());
}

static VALUE bin_str(const void *p, size_t n) {
    return rb_enc_associate(rb_str_new((const char *)p, (long)n), rb_ascii8bit_encoding());
}

/* ---- errors ----------------------------------------------------------- */

static VALUE error_class(c0_status code) {
    switch (code) {
        case C0_ERR_UNASSIGNED: return eUnassignedCodeError;
        case C0_ERR_UNEXPECTED_END: return eUnexpectedEndError;
        case C0_ERR_SYNTAX:
        case C0_ERR_TOO_DEEP: return eSyntaxError;
        case C0_ERR_NOT_FOUND: return eKeyError;
        case C0_ERR_BAD_NAME:
        case C0_ERR_BAD_STATE: return eBuildError;
        default: return eError;
    }
}

static const char *status_message(c0_status code) {
    switch (code) {
        case C0_ERR_SYNTAX: return "malformed input";
        case C0_ERR_UNASSIGNED: return "unassigned control code";
        case C0_ERR_UNEXPECTED_END: return "unexpected end of input";
        case C0_ERR_TOO_DEEP: return "levels nested too deep";
        case C0_ERR_NOT_SCALAR: return "unit is not a scalar (a nested level or a reference)";
        case C0_ERR_NOT_LEVEL: return "unit is not a nested level";
        case C0_ERR_NOT_LIST: return "level is not a list";
        case C0_ERR_NOT_REFERENCE: return "unit is not a reference";
        case C0_ERR_NEEDS_DECODE: return "text needs decoding";
        case C0_ERR_NOT_FOUND: return "not found";
        case C0_ERR_BAD_NAME: return "not a legal name (a control byte or edge whitespace)";
        case C0_ERR_BAD_STATE: return "builder misuse";
        case C0_ERR_OOM: return "out of memory";
        default: return "error";
    }
}

/* Raise for a c0_error with position detail. */
static void raise_error(const c0_error *err) {
    VALUE exc;
    if (err->code == C0_ERR_OOM) rb_memerror();
    exc = rb_exc_new_str(error_class(err->code),
                         rb_sprintf("%s at byte %ld", err->msg && *err->msg ? err->msg : status_message(err->code),
                                    (long)err->pos));
    rb_ivar_set(exc, rb_intern("@position"), LONG2NUM((long)err->pos));
    rb_exc_raise(exc);
}

/* Raise for a bare status (no position). */
static void raise_status(c0_status code) {
    if (code == C0_ERR_OOM) rb_memerror();
    rb_raise(error_class(code), "%s", status_message(code));
}

/* ---- bytewise helpers --------------------------------------------------- */

static VALUE ext_is_assigned(VALUE self, VALUE byte) {
    (void)self;
    return c0_is_assigned((uint8_t)NUM2INT(byte)) ? Qtrue : Qfalse;
}

static VALUE ext_is_layout(VALUE self, VALUE byte) {
    (void)self;
    return c0_is_layout((uint8_t)NUM2INT(byte)) ? Qtrue : Qfalse;
}

static VALUE ext_is_plain(VALUE self, VALUE str) {
    buf_t b = get_buf(str);
    (void)self;
    return c0_is_plain(b.p, b.len) ? Qtrue : Qfalse;
}

static VALUE ext_trim(VALUE self, VALUE str) {
    buf_t b = get_buf(str);
    c0_bytes t = c0_trim(c0_bytes_of(b.p, b.len));
    (void)self;
    return substr(b, t.ptr, t.len);
}

static VALUE ext_decode_text(VALUE self, VALUE str) {
    buf_t b = get_buf(str);
    VALUE out = rb_str_buf_new((long)b.len);
    size_t n = c0_decode_text(b.p, b.len, (uint8_t *)RSTRING_PTR(out));
    (void)self;
    rb_str_set_len(out, (long)n);
    return rb_enc_associate(out, rb_ascii8bit_encoding());
}

/* ---- validation --------------------------------------------------------- */

static VALUE ext_validate(VALUE self, VALUE str) {
    buf_t b = get_buf(str);
    c0_error err;
    (void)self;
    if (c0_validate(b.p, b.len, &err) != C0_OK) raise_error(&err);
    return Qnil;
}

static VALUE ext_canonical(VALUE self, VALUE str) {
    buf_t b = get_buf(str);
    (void)self;
    return c0_canonical(b.p, b.len) ? Qtrue : Qfalse;
}

/* ---- units and values --------------------------------------------------- */

static VALUE ext_unit_type(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    (void)self;
    return INT2NUM((int)c0_unit_type(slice_of(b, s, e)));
}

/* The logical value of the raw unit at [s, e): a shared byteslice when no
 * decoding is needed, a fresh string otherwise. */
static VALUE ext_value(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    c0_bytes raw = slice_of(b, s, e), v;
    c0_status st = c0_value(raw, NULL, &v);
    (void)self;
    if (st == C0_ERR_NEEDS_DECODE) {
        VALUE out = rb_str_buf_new((long)raw.len);
        st = c0_value(raw, (uint8_t *)RSTRING_PTR(out), &v);
        if (st != C0_OK) raise_status(st);
        rb_str_set_len(out, (long)v.len);
        return rb_enc_associate(out, rb_ascii8bit_encoding());
    }
    if (st != C0_OK) raise_status(st);
    return substr(b, v.ptr, v.len);
}

/* The raw unit at [s, e) as a nested level: the body's [start, stop) in the buffer. */
static VALUE ext_unit_level(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    c0_body body;
    c0_status st = c0_unit_level(slice_of(b, s, e), &body);
    long base;
    (void)self;
    if (st != C0_OK) raise_status(st);
    base = (long)(body.buf - b.p);
    return rb_ary_new3(2, LONG2NUM(base + (long)body.start), LONG2NUM(base + (long)body.stop));
}

/* The raw unit at [s, e) as a reference: its segments as [start, end] pairs. */
static VALUE ext_unit_ref(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    c0_ref ref;
    c0_status st = c0_unit_ref(slice_of(b, s, e), &ref);
    VALUE out;
    size_t i;
    (void)self;
    if (st != C0_OK) raise_status(st);
    out = rb_ary_new_capa((long)ref.count);
    for (i = 0; i < ref.count; i++) rb_ary_push(out, span(b, ref.seg[i]));
    return out;
}

static VALUE collect_units(buf_t b, c0_unit_iter *it) {
    VALUE out = rb_ary_new();
    c0_bytes raw;
    while (c0_next_unit(it, &raw)) rb_ary_push(out, span(b, raw));
    if (it->err.code) raise_error(&it->err);
    return out;
}

/* The raw unit at [s, e) as a flat list: its items' raw ranges. */
static VALUE ext_unit_list(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    c0_unit_iter it;
    c0_status st = c0_unit_list(slice_of(b, s, e), &it);
    (void)self;
    if (st != C0_OK) raise_status(st);
    return collect_units(b, &it);
}

/* ---- records ------------------------------------------------------------ */

static c0_record record_of(buf_t b, VALUE s, VALUE e) {
    c0_record r;
    long start = NUM2LONG(s), stop = NUM2LONG(e);
    check_range(b, start, stop);
    r.buf = b.p;
    r.start = (size_t)start;
    r.stop = (size_t)stop;
    return r;
}

static VALUE ext_record_keyed(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    (void)self;
    return c0_record_keyed(record_of(b, s, e)) ? Qtrue : Qfalse;
}

/* Positional units of the record at [s, e): raw ranges. */
static VALUE ext_record_units(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    c0_unit_iter it = c0_record_units(record_of(b, s, e));
    (void)self;
    return collect_units(b, &it);
}

/* Keyed units of the record (or heading) at [s, e): [ks, ke, vs, ve] each. */
static VALUE ext_record_pairs(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    c0_pair_iter it = c0_record_pairs(record_of(b, s, e));
    VALUE out = rb_ary_new();
    c0_bytes k, v;
    (void)self;
    while (c0_next_pair(&it, &k, &v)) {
        long ks = (long)(k.ptr - b.p), vs = (long)(v.ptr - b.p);
        rb_ary_push(out, rb_ary_new3(4, LONG2NUM(ks), LONG2NUM(ks + (long)k.len), LONG2NUM(vs),
                                     LONG2NUM(vs + (long)v.len)));
    }
    if (it.err.code) raise_error(&it.err);
    return out;
}

/* ---- bodies ------------------------------------------------------------- */

static c0_body body_of(buf_t b, VALUE s, VALUE e) {
    c0_body body;
    long start = NUM2LONG(s), stop = NUM2LONG(e);
    check_range(b, start, stop);
    body.buf = b.p;
    body.start = (size_t)start;
    body.stop = (size_t)stop;
    return body;
}

/* Files of the body at [s, e): [name_start, name_end, start, stop] each (name trimmed). */
static VALUE ext_files(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    c0_file_iter it = c0_body_files(body_of(b, s, e));
    c0_file f;
    VALUE out = rb_ary_new();
    (void)self;
    while (c0_next_file(&it, &f)) {
        c0_bytes n = c0_file_name(f);
        long ns = (long)(n.ptr - b.p);
        rb_ary_push(out, rb_ary_new3(4, LONG2NUM(ns), LONG2NUM(ns + (long)n.len), LONG2NUM((long)f.start),
                                     LONG2NUM((long)f.stop)));
    }
    if (it.err.code) raise_error(&it.err);
    return out;
}

/* Groups of the range [s, e) (a body or one file): [depth, name_start, name_end, start, stop] each. */
static VALUE ext_groups(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    c0_group_iter it = c0_body_groups(body_of(b, s, e));
    c0_group g;
    VALUE out = rb_ary_new();
    (void)self;
    while (c0_next_group(&it, &g)) {
        c0_bytes n = c0_group_name(g);
        long ns = (long)(n.ptr - b.p);
        rb_ary_push(out, rb_ary_new3(5, LONG2NUM((long)g.depth), LONG2NUM(ns), LONG2NUM(ns + (long)n.len),
                                     LONG2NUM((long)g.start), LONG2NUM((long)g.stop)));
    }
    if (it.err.code) raise_error(&it.err);
    return out;
}

static c0_group group_of(buf_t b, VALUE s, VALUE e) {
    c0_group g;
    long start = NUM2LONG(s), stop = NUM2LONG(e);
    check_range(b, start, stop);
    g.buf = b.p;
    g.depth = 0;
    g.name_start = g.name_end = (size_t)start;
    g.start = (size_t)start;
    g.stop = (size_t)stop;
    return g;
}

/* The header row of the group whose contents are [s, e): a record range, or nil. */
static VALUE ext_group_header(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    c0_record h;
    (void)self;
    if (!c0_group_header(group_of(b, s, e), &h)) return Qnil;
    return rb_ary_new3(2, LONG2NUM((long)h.start), LONG2NUM((long)h.stop));
}

/* Live records of the group whose contents are [s, e): record ranges. */
static VALUE ext_group_records(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    c0_record_iter it = c0_group_records(group_of(b, s, e));
    c0_record r;
    VALUE out = rb_ary_new();
    (void)self;
    while (c0_next_record(&it, &r)) {
        rb_ary_push(out, rb_ary_new3(2, LONG2NUM((long)r.start), LONG2NUM((long)r.stop)));
    }
    if (it.err.code) raise_error(&it.err);
    return out;
}

static VALUE ext_body_bare(VALUE self, VALUE str, VALUE s, VALUE e) {
    buf_t b = get_buf(str);
    (void)self;
    return c0_body_bare(body_of(b, s, e)) ? Qtrue : Qfalse;
}

/* ---- documents ---------------------------------------------------------- */

static VALUE document_array(const c0_document *d) {
    return rb_ary_new3(9, LONG2NUM((long)d->start), LONG2NUM((long)d->stop), d->has_syn ? Qtrue : Qfalse,
                       d->has_eot ? Qtrue : Qfalse, LONG2NUM((long)d->heading_start),
                       LONG2NUM((long)d->heading_end), LONG2NUM((long)d->body.start),
                       LONG2NUM((long)d->body.stop), UINT2NUM(d->warnings));
}

/* The document at `start`: [start, stop, syn?, eot?, heading_start,
 * heading_end, body_start, body_stop, warning_bits]. */
static VALUE ext_document(VALUE self, VALUE str, VALUE start) {
    buf_t b = get_buf(str);
    c0_document d;
    c0_error err;
    long s = NUM2LONG(start);
    (void)self;
    check_range(b, s, s);
    if (c0_document_read(b.p, b.len, (size_t)s, &d, &err) != C0_OK) raise_error(&err);
    return document_array(&d);
}

/* Every document of a container: [[doc...], ..., em?, em_pos]. */
static VALUE ext_documents(VALUE self, VALUE str) {
    buf_t b = get_buf(str);
    c0_doc_iter it = c0_documents(b.p, b.len);
    c0_document d;
    VALUE docs = rb_ary_new();
    (void)self;
    while (c0_next_document(&it, &d)) rb_ary_push(docs, document_array(&d));
    if (it.err.code) raise_error(&it.err);
    return rb_ary_new3(3, docs, it.has_em ? Qtrue : Qfalse, LONG2NUM((long)it.em_pos));
}

/* ---- streams ------------------------------------------------------------ */

/* [committed_end, torn?, [[start, end, damaged?], ...]] */
static VALUE ext_stream(VALUE self, VALUE str) {
    buf_t b = get_buf(str);
    c0_stream s = c0_stream_read(b.p, b.len);
    c0_block_iter it = c0_stream_blocks(&s);
    c0_bytes blk;
    int damaged;
    VALUE blocks = rb_ary_new_capa((long)s.block_count);
    (void)self;
    while (c0_next_block(&it, &blk, &damaged)) {
        long bs = (long)(blk.ptr - b.p);
        rb_ary_push(blocks, rb_ary_new3(3, LONG2NUM(bs), LONG2NUM(bs + (long)blk.len), damaged ? Qtrue : Qfalse));
    }
    return rb_ary_new3(3, LONG2NUM((long)s.committed_end), s.torn ? Qtrue : Qfalse, blocks);
}

/* The undamaged committed blocks, ETB markers and payloads removed. */
static VALUE ext_stream_undamaged(VALUE self, VALUE str) {
    buf_t b = get_buf(str);
    c0_stream s = c0_stream_read(b.p, b.len);
    VALUE out = rb_str_buf_new((long)s.committed_end + 1);
    size_t n = c0_stream_undamaged(&s, (uint8_t *)RSTRING_PTR(out));
    (void)self;
    rb_str_set_len(out, (long)n);
    return rb_enc_associate(out, rb_ascii8bit_encoding());
}

static VALUE ext_last_commit_end(VALUE self, VALUE str) {
    buf_t b = get_buf(str);
    (void)self;
    return LONG2NUM((long)c0_stream_last_commit_end(b.p, b.len));
}

/* ---- pretty form -------------------------------------------------------- */

static VALUE ext_pretty_format(VALUE self, VALUE str, VALUE indent, VALUE mode) {
    buf_t b = get_buf(str);
    const char *ind = NIL_P(indent) ? NULL : StringValueCStr(indent);
    int m = NUM2INT(mode);
    size_t outlen;
    c0_error err;
    char *p;
    VALUE out;
    (void)self;
    if (m < C0_PRETTY_COMPACT || m > C0_PRETTY_SPACED) rb_raise(rb_eArgError, "unknown pretty mode %d", m);
    p = c0_pretty_format(b.p, b.len, ind, (c0_pretty_mode)m, &outlen, &err);
    if (!p) {
        if (err.code == C0_ERR_SYNTAX && err.msg && strcmp(err.msg, "glyph in data") == 0) {
            rb_raise(eGlyphInDataError,
                     "value contains a Control Picture character and cannot be shown in pretty form (byte %ld)",
                     (long)err.pos);
        }
        raise_error(&err);
    }
    out = rb_utf8_str_new(p, (long)outlen);
    free(p);
    return out;
}

static VALUE ext_pretty_parse(VALUE self, VALUE str) {
    buf_t b = get_buf(str);
    size_t outlen;
    uint8_t *p = c0_pretty_parse((const char *)b.p, b.len, &outlen);
    VALUE out;
    (void)self;
    if (!p) rb_memerror();
    out = bin_str(p, outlen);
    free(p);
    return out;
}

/* ---- Builder (TypedData over c0_builder) -------------------------------- */

static void builder_free(void *p) {
    c0_builder_free((c0_builder *)p);
    xfree(p);
}

static size_t builder_memsize(const void *p) {
    const c0_builder *b = (const c0_builder *)p;
    return sizeof(*b) + b->cap + b->stack_cap * 2 * sizeof(int);
}

static const rb_data_type_t builder_type = {
    "C0::Builder",
    {NULL, builder_free, builder_memsize, NULL, {NULL}},
    NULL,
    NULL,
    RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE builder_alloc(VALUE klass) {
    c0_builder *b;
    VALUE obj = TypedData_Make_Struct(klass, c0_builder, &builder_type, b);
    c0_builder_init(b);
    return obj;
}

static c0_builder *get_builder(VALUE self) {
    c0_builder *b;
    TypedData_Get_Struct(self, c0_builder, &builder_type, b);
    return b;
}

/* After a write: a sticky error status becomes an exception. */
static void builder_check(c0_builder *b) {
    if (b->status != C0_OK) {
        c0_status st = b->status;
        b->status = C0_OK; /* the builder stays usable; the bad call did not land */
        raise_status(st);
    }
}

/* A Ruby value as bytes (Symbols become their names). */
static c0_bytes bytes_arg(VALUE v) {
    if (SYMBOL_P(v)) v = rb_sym2str(v);
    StringValue(v);
    return c0_bytes_of((const uint8_t *)RSTRING_PTR(v), (size_t)RSTRING_LEN(v));
}

/* A name: checked before anything is written, so a bad one leaves no bytes. */
static c0_bytes name_arg(VALUE v, const char *what) {
    c0_bytes n = bytes_arg(v);
    if (!c0_is_name(n.ptr, n.len)) {
        rb_raise(eBuildError, "%s is not a legal name (no control bytes, no edge whitespace): %+" PRIsVALUE, what,
                 SYMBOL_P(v) ? rb_sym2str(v) : v);
    }
    return n;
}

/* Splat or one Array: the elements as an Array. */
static VALUE splat_or_array(int argc, VALUE *argv) {
    if (argc == 1 && RB_TYPE_P(argv[0], T_ARRAY)) return argv[0];
    return rb_ary_new_from_values(argc, argv);
}

/* c0_bytes for each element of an Array (names when `names`). The array is
 * backed by a GC-managed temporary String stored in *tmp; the caller keeps
 * `tmp` alive (RB_GC_GUARD) until it is done with the pointer. */
static c0_bytes *bytes_array(VALUE ary, int names, const char *what, VALUE *tmp, long *count) {
    long i, n = RARRAY_LEN(ary);
    c0_bytes *out;
    *tmp = rb_str_tmp_new((long)((n > 0 ? n : 1) * sizeof(c0_bytes)));
    out = (c0_bytes *)RSTRING_PTR(*tmp);
    for (i = 0; i < n; i++) {
        VALUE v = RARRAY_AREF(ary, i);
        out[i] = names ? name_arg(v, what) : bytes_arg(v);
    }
    *count = n;
    return out;
}

static VALUE builder_initialize(VALUE self) {
    (void)self;
    return self;
}

/* bytes → a fresh binary String of what has been written so far. */
static VALUE builder_bytes(VALUE self) {
    c0_builder *b = get_builder(self);
    c0_bytes out;
    builder_check(b);
    out = c0_builder_bytes(b);
    return bin_str(out.ptr, out.len);
}

static VALUE builder_size(VALUE self) { return LONG2NUM((long)get_builder(self)->len); }

static VALUE builder_depth(VALUE self) { return LONG2NUM((long)get_builder(self)->depth); }

/* -- primitives: one method per code -- */

/* A reference path: one to three non-empty names, as c0_bytes backed by *tmp. */
static c0_bytes *path_arg(VALUE path, VALUE *tmp, long *count) {
    c0_bytes *arr;
    long i;
    if (RARRAY_LEN(path) < 1 || RARRAY_LEN(path) > 3) {
        rb_raise(eBuildError, "a reference is a group name or a path of two or three segments");
    }
    arr = bytes_array(path, 1, "reference segment", tmp, count);
    for (i = 0; i < *count; i++) {
        if (arr[i].len == 0) rb_raise(eBuildError, "reference segment must not be empty");
    }
    return arr;
}

/* fs(name): FS and a file name; ends any open record. */
static VALUE builder_fs(VALUE self, VALUE name) {
    c0_builder *b = get_builder(self);
    c0_bytes n = name_arg(name, "file name");
    c0_builder_fs(b, n.ptr, n.len);
    builder_check(b);
    return self;
}

/* gs(name = nil): GS and, when given, a group name. gs.gs("sub") is depth 2. */
static VALUE builder_gs(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE name;
    rb_scan_args(argc, argv, "01", &name);
    if (NIL_P(name)) {
        c0_builder_gs(b);
    } else {
        c0_bytes n = name_arg(name, "group name");
        c0_builder_gs_name(b, n.ptr, n.len);
    }
    builder_check(b);
    return self;
}

/* rs(value = nil): RS and, when given, the record's first value. */
static VALUE builder_rs(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE value;
    rb_scan_args(argc, argv, "01", &value);
    if (NIL_P(value)) {
        c0_builder_rs(b);
    } else {
        c0_bytes v = bytes_arg(value);
        c0_builder_rs_value(b, v.ptr, v.len);
    }
    builder_check(b);
    return self;
}

/* us(value = nil): US and, when given, the value that follows it. */
static VALUE builder_us(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE value;
    rb_scan_args(argc, argv, "01", &value);
    if (NIL_P(value)) {
        c0_builder_us(b);
    } else {
        c0_bytes v = bytes_arg(value);
        c0_builder_us_value(b, v.ptr, v.len);
    }
    builder_check(b);
    return self;
}

/* sub(value = nil): SUB and, when given, the new side of a substitution. C0-DIFF
 * only: rs("old").sub("new") is a replace-all; in a data body SUB is an error.
 * Does not count as a unit. */
static VALUE builder_sub(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE value;
    rb_scan_args(argc, argv, "01", &value);
    if (NIL_P(value)) {
        c0_builder_sub(b);
    } else {
        c0_bytes v = bytes_arg(value);
        c0_builder_sub_value(b, v.ptr, v.len);
    }
    builder_check(b);
    return self;
}

/* soh(name = nil): SOH and, when given, a key. Bare before rs it opens a header row. */
static VALUE builder_soh(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE name;
    rb_scan_args(argc, argv, "01", &name);
    if (NIL_P(name)) {
        c0_builder_soh(b);
    } else {
        c0_bytes n = name_arg(name, "key");
        c0_builder_soh_name(b, n.ptr, n.len);
    }
    builder_check(b);
    return self;
}

/* dle: open a nested level (the record state is saved). */
static VALUE builder_dle(VALUE self) {
    c0_builder *b = get_builder(self);
    c0_builder_dle(b);
    builder_check(b);
    return self;
}

/* can: close the innermost level; C0::BuildError if none is open. */
static VALUE builder_can(VALUE self) {
    c0_builder *b = get_builder(self);
    if (b->depth == 0) rb_raise(eBuildError, "CAN with no open level");
    c0_builder_can(b);
    builder_check(b);
    return self;
}

/* bel(text = nil): BEL and, when given, a note. Bare, it marks the element that follows dead. */
static VALUE builder_bel(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE text;
    rb_scan_args(argc, argv, "01", &text);
    if (NIL_P(text)) {
        c0_builder_bel(b);
    } else {
        c0_bytes t = bytes_arg(text);
        if (t.len == 0) rb_raise(rb_eArgError, "a note needs content: bare BEL marks the next element dead");
        c0_builder_bel_text(b, t.ptr, t.len);
    }
    builder_check(b);
    return self;
}

/* enq(name) or enq(group, record[, field]): ENQ and a reference. */
static VALUE builder_enq(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE tmp;
    long n;
    c0_bytes *arr = path_arg(splat_or_array(argc, argv), &tmp, &n);
    c0_builder_enq_path(b, arr, (size_t)n);
    RB_GC_GUARD(tmp);
    builder_check(b);
    return self;
}

/* -- documents -- */

static VALUE builder_key_pair(VALUE key, VALUE val, VALUE self);

static int syn_pair_i(VALUE key, VALUE val, VALUE self) {
    builder_key_pair(key, val, self);
    return ST_CONTINUE;
}

/* syn(pairs = {}, **pairs): SYN and, when given, the heading's keyed units in order. */
static VALUE builder_syn(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE pairs, kw;
    rb_scan_args(argc, argv, "01:", &pairs, &kw);
    c0_builder_syn(b);
    builder_check(b);
    if (!NIL_P(pairs)) rb_hash_foreach(rb_convert_type(pairs, T_HASH, "Hash", "to_hash"), syn_pair_i, self);
    if (!NIL_P(kw)) rb_hash_foreach(kw, syn_pair_i, self);
    return self;
}

static VALUE builder_eot(VALUE self) {
    c0_builder *b = get_builder(self);
    c0_builder_eot(b);
    builder_check(b);
    return self;
}

/* etb(payload = nil): a commit, with an optional plain payload. */
static VALUE builder_etb(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE payload;
    rb_scan_args(argc, argv, "01", &payload);
    if (NIL_P(payload)) {
        c0_builder_etb(b);
    } else {
        c0_bytes p = name_arg(payload, "ETB payload");
        c0_builder_etb_payload(b, p.ptr, p.len);
    }
    builder_check(b);
    return self;
}

/* em(tail): EM and the raw tail; nothing may follow. */
static VALUE builder_em(VALUE self, VALUE tail) {
    c0_builder *b = get_builder(self);
    c0_bytes t = bytes_arg(tail);
    c0_builder_em(b, t.ptr, t.len);
    builder_check(b);
    return self;
}

/* -- structure -- */

/* file(name) { ... } */
static VALUE builder_file(VALUE self, VALUE name) {
    c0_builder *b = get_builder(self);
    c0_bytes n = name_arg(name, "file name");
    c0_build_file(b, n.ptr, n.len);
    builder_check(b);
    if (rb_block_given_p()) rb_yield(self);
    return self;
}

static VALUE builder_header_ary(VALUE self, VALUE names) {
    c0_builder *b = get_builder(self);
    VALUE tmp;
    long n;
    c0_bytes *arr = bytes_array(names, 1, "header name", &tmp, &n);
    c0_build_header(b, arr, (size_t)n);
    RB_GC_GUARD(tmp);
    builder_check(b);
    return self;
}

/* group(name, headers = nil, depth = 1) { ... }: GS×depth name, then a header row when given. */
static VALUE builder_group(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE name, headers, depth;
    c0_bytes n;
    long d;
    rb_scan_args(argc, argv, "12", &name, &headers, &depth);
    d = NIL_P(depth) ? 1 : NUM2LONG(depth);
    if (d < 1) rb_raise(rb_eArgError, "depth must be at least 1");
    n = name_arg(name, "group name");
    c0_build_section(b, n.ptr, n.len, (size_t)d);
    builder_check(b);
    if (!NIL_P(headers)) builder_header_ary(self, rb_convert_type(headers, T_ARRAY, "Array", "to_ary"));
    if (rb_block_given_p()) rb_yield(self);
    return self;
}

/* section(name, depth = 1) { ... }: document mode, a heading at depth. */
static VALUE builder_section(int argc, VALUE *argv, VALUE self) {
    VALUE name, depth, args[3];
    rb_scan_args(argc, argv, "11", &name, &depth);
    args[0] = name;
    args[1] = Qnil;
    args[2] = NIL_P(depth) ? INT2FIX(1) : depth;
    return builder_group(3, args, self);
}

/* header(*names) or header(names): SOH RS name US name … */
static VALUE builder_header(int argc, VALUE *argv, VALUE self) {
    return builder_header_ary(self, splat_or_array(argc, argv));
}

/* -- records -- */

/* record(*fields) or record(fields): RS and the units; record() opens an empty record. */
static VALUE builder_record(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE fields = splat_or_array(argc, argv);
    VALUE tmp;
    long n;
    c0_bytes *arr = bytes_array(fields, 0, "field", &tmp, &n);
    c0_build_record(b, arr, (size_t)n);
    RB_GC_GUARD(tmp);
    builder_check(b);
    return self;
}

/* field(value): the next unit of the open record (opens one if none). */
static VALUE builder_field(VALUE self, VALUE value) {
    c0_builder *b = get_builder(self);
    c0_bytes v = bytes_arg(value);
    c0_build_field(b, v.ptr, v.len);
    builder_check(b);
    return self;
}

static VALUE builder_block(VALUE self, VALUE text) {
    c0_builder *b = get_builder(self);
    c0_bytes v = bytes_arg(text);
    c0_build_block(b, v.ptr, v.len);
    builder_check(b);
    return self;
}

static VALUE builder_item(VALUE self, VALUE text) {
    c0_builder *b = get_builder(self);
    c0_bytes v = bytes_arg(text);
    c0_build_item(b, v.ptr, v.len);
    builder_check(b);
    return self;
}

static VALUE level_close_ensure(VALUE self) {
    c0_builder *b = get_builder(self);
    if (b->depth > 0) c0_build_level_close(b);
    return Qnil;
}

static VALUE yield_self(VALUE self) { return rb_yield(self); }

/* Open a level, run the block, close the level (even on a raise). */
static VALUE builder_in_level(VALUE self) {
    c0_builder *b = get_builder(self);
    builder_check(b);
    if (rb_block_given_p()) rb_ensure(yield_self, self, level_close_ensure, self);
    else level_close_ensure(self);
    builder_check(b);
    return self;
}

/* One keyed unit: SOH key US value, in the open record or the heading. */
static VALUE builder_key_pair(VALUE key, VALUE val, VALUE self) {
    c0_builder *b = get_builder(self);
    c0_bytes k = name_arg(key, "key"), v = bytes_arg(val);
    c0_build_key(b, k.ptr, k.len, v.ptr, v.len);
    builder_check(b);
    return self;
}

/* key(name, value) or key(name) { ... }: a keyed unit, the block form writing a nested level as its value. */
static VALUE builder_key(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE name, value;
    rb_scan_args(argc, argv, "11", &name, &value);
    if (argc == 2) return builder_key_pair(name, value, self);
    if (!rb_block_given_p()) rb_raise(rb_eArgError, "key needs a value or a block");
    {
        c0_bytes k = name_arg(name, "key");
        c0_build_key_level_open(b, k.ptr, k.len);
    }
    return builder_in_level(self);
}

/* heading_level(key) { ... }: a heading key whose value is a level (the blob table). */
static VALUE builder_heading_level(VALUE self, VALUE key) {
    VALUE args[1];
    args[0] = key;
    return builder_key(1, args, self);
}

static int map_pair_i(VALUE key, VALUE val, VALUE self) {
    builder_key_pair(key, val, self);
    return ST_CONTINUE;
}

/* map(pairs): a keyed record, entries in the order given. */
static VALUE builder_map(VALUE self, VALUE pairs) {
    c0_builder *b = get_builder(self);
    c0_build_record(b, NULL, 0);
    builder_check(b);
    rb_hash_foreach(rb_convert_type(pairs, T_HASH, "Hash", "to_hash"), map_pair_i, self);
    return self;
}

/* level { ... }: a nested level as the next unit; inside, the builder is at the top of a fresh body. */
static VALUE builder_level(VALUE self) {
    c0_builder *b = get_builder(self);
    c0_build_level_open(b);
    return builder_in_level(self);
}

/* list(items) or list(*items): a flat list as the next unit. */
static VALUE builder_list(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE items = splat_or_array(argc, argv);
    VALUE tmp;
    long n;
    c0_bytes *arr = bytes_array(items, 0, "item", &tmp, &n);
    c0_build_list(b, arr, (size_t)n);
    RB_GC_GUARD(tmp);
    builder_check(b);
    return self;
}

/* ref(name) or ref(group, record[, field]): a reference as the next unit. */
static VALUE builder_ref(int argc, VALUE *argv, VALUE self) {
    c0_builder *b = get_builder(self);
    VALUE tmp;
    long n;
    c0_bytes *arr = path_arg(splat_or_array(argc, argv), &tmp, &n);
    c0_build_ref_path(b, arr, (size_t)n);
    RB_GC_GUARD(tmp);
    builder_check(b);
    return self;
}

/* note(text): BEL and a note (plain, or text when it must be). */
static VALUE builder_note(VALUE self, VALUE text) {
    c0_builder *b = get_builder(self);
    c0_bytes t = bytes_arg(text);
    if (t.len == 0) rb_raise(rb_eArgError, "a note needs content: BEL before a code marks it dead");
    c0_build_note(b, t.ptr, t.len);
    builder_check(b);
    return self;
}

/* ---- init --------------------------------------------------------------- */

void Init_c0_ext(void) {
    mC0 = rb_define_module("C0");
    mExt = rb_define_module_under(mC0, "Ext");
    mPretty = rb_define_module_under(mC0, "Pretty");

    eError = rb_define_class_under(mC0, "Error", rb_eStandardError);
    eSyntaxError = rb_define_class_under(mC0, "SyntaxError", eError);
    rb_define_attr(eSyntaxError, "position", 1, 0);
    eUnassignedCodeError = rb_define_class_under(mC0, "UnassignedCodeError", eSyntaxError);
    eUnexpectedEndError = rb_define_class_under(mC0, "UnexpectedEndError", eSyntaxError);
    eKeyError = rb_define_class_under(mC0, "KeyError", eError);
    eBuildError = rb_define_class_under(mC0, "BuildError", eError);
    eGlyphInDataError = rb_define_class_under(mPretty, "GlyphInDataError", eError);

    rb_define_const(mC0, "VERSION", rb_str_freeze(rb_utf8_str_new_cstr(C0_VERSION)));

    rb_define_module_function(mExt, "is_assigned", ext_is_assigned, 1);
    rb_define_module_function(mExt, "is_layout", ext_is_layout, 1);
    rb_define_module_function(mExt, "is_plain", ext_is_plain, 1);
    rb_define_module_function(mExt, "trim", ext_trim, 1);
    rb_define_module_function(mExt, "decode_text", ext_decode_text, 1);
    rb_define_module_function(mExt, "validate", ext_validate, 1);
    rb_define_module_function(mExt, "canonical", ext_canonical, 1);
    rb_define_module_function(mExt, "unit_type", ext_unit_type, 3);
    rb_define_module_function(mExt, "value", ext_value, 3);
    rb_define_module_function(mExt, "unit_level", ext_unit_level, 3);
    rb_define_module_function(mExt, "unit_ref", ext_unit_ref, 3);
    rb_define_module_function(mExt, "unit_list", ext_unit_list, 3);
    rb_define_module_function(mExt, "record_keyed", ext_record_keyed, 3);
    rb_define_module_function(mExt, "record_units", ext_record_units, 3);
    rb_define_module_function(mExt, "record_pairs", ext_record_pairs, 3);
    rb_define_module_function(mExt, "files", ext_files, 3);
    rb_define_module_function(mExt, "groups", ext_groups, 3);
    rb_define_module_function(mExt, "group_header", ext_group_header, 3);
    rb_define_module_function(mExt, "group_records", ext_group_records, 3);
    rb_define_module_function(mExt, "body_bare", ext_body_bare, 3);
    rb_define_module_function(mExt, "document", ext_document, 2);
    rb_define_module_function(mExt, "documents", ext_documents, 1);
    rb_define_module_function(mExt, "stream", ext_stream, 1);
    rb_define_module_function(mExt, "stream_undamaged", ext_stream_undamaged, 1);
    rb_define_module_function(mExt, "last_commit_end", ext_last_commit_end, 1);
    rb_define_module_function(mExt, "pretty_format", ext_pretty_format, 3);
    rb_define_module_function(mExt, "pretty_parse", ext_pretty_parse, 1);

    cBuilder = rb_define_class_under(mC0, "Builder", rb_cObject);
    rb_define_alloc_func(cBuilder, builder_alloc);
    rb_define_method(cBuilder, "initialize", builder_initialize, 0);
    rb_define_method(cBuilder, "bytes", builder_bytes, 0);
    rb_define_method(cBuilder, "bytesize", builder_size, 0);
    rb_define_method(cBuilder, "depth", builder_depth, 0);
    rb_define_method(cBuilder, "fs", builder_fs, 1);
    rb_define_method(cBuilder, "gs", builder_gs, -1);
    rb_define_method(cBuilder, "rs", builder_rs, -1);
    rb_define_method(cBuilder, "us", builder_us, -1);
    rb_define_method(cBuilder, "sub", builder_sub, -1);
    rb_define_method(cBuilder, "soh", builder_soh, -1);
    rb_define_method(cBuilder, "dle", builder_dle, 0);
    rb_define_method(cBuilder, "can", builder_can, 0);
    rb_define_method(cBuilder, "bel", builder_bel, -1);
    rb_define_method(cBuilder, "enq", builder_enq, -1);
    rb_define_method(cBuilder, "syn", builder_syn, -1);
    rb_define_method(cBuilder, "heading_level", builder_heading_level, 1);
    rb_define_method(cBuilder, "eot", builder_eot, 0);
    rb_define_method(cBuilder, "etb", builder_etb, -1);
    rb_define_method(cBuilder, "em", builder_em, 1);
    rb_define_method(cBuilder, "file", builder_file, 1);
    rb_define_method(cBuilder, "group", builder_group, -1);
    rb_define_method(cBuilder, "section", builder_section, -1);
    rb_define_method(cBuilder, "header", builder_header, -1);
    rb_define_method(cBuilder, "record", builder_record, -1);
    rb_define_method(cBuilder, "field", builder_field, 1);
    rb_define_method(cBuilder, "block", builder_block, 1);
    rb_define_method(cBuilder, "item", builder_item, 1);
    rb_define_method(cBuilder, "map", builder_map, 1);
    rb_define_method(cBuilder, "key", builder_key, -1);
    rb_define_method(cBuilder, "level", builder_level, 0);
    rb_define_method(cBuilder, "list", builder_list, -1);
    rb_define_method(cBuilder, "ref", builder_ref, -1);
    rb_define_method(cBuilder, "note", builder_note, 1);
}
