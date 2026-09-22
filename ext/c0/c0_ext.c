/* Ruby C extension: thin, fast binding over the c0 single-header C core.
 *
 * The scan-heavy work happens in C; the reader functions return byte offsets so
 * the Ruby layer can hand back shared (zero-copy) byteslices into the input. */
#include "ruby.h"

#define C0_IMPLEMENTATION
#include "c0.h"

/* Append a [start, end] pair for the slice [b.ptr, b.ptr+b.len) onto ary. */
static void push_span(VALUE ary, const uint8_t *base, c0_bytes b) {
    long s = (long)(b.ptr - base);
    rb_ary_push(ary, rb_ary_new3(2, LONG2NUM(s), LONG2NUM(s + (long)b.len)));
}

static VALUE ext_is_assigned(VALUE self, VALUE byte) {
    (void)self;
    return c0_is_assigned((uint8_t)NUM2INT(byte)) ? Qtrue : Qfalse;
}

static VALUE ext_canonical(VALUE self, VALUE str) {
    (void)self;
    StringValue(str);
    return c0_canonical((const uint8_t *)RSTRING_PTR(str), (size_t)RSTRING_LEN(str))
               ? Qtrue
               : Qfalse;
}

static VALUE ext_unescape(VALUE self, VALUE str) {
    long len;
    VALUE out;
    size_t n;
    (void)self;
    StringValue(str);
    len = RSTRING_LEN(str);
    out = rb_str_buf_new(len);
    n = c0_unescape((const uint8_t *)RSTRING_PTR(str), (size_t)len, (uint8_t *)RSTRING_PTR(out));
    rb_str_set_len(out, (long)n);
    return out;
}

static VALUE ext_tokenize(VALUE self, VALUE str) {
    c0_tokenizer tz;
    c0_token t;
    c0_step s;
    VALUE arr;
    (void)self;
    StringValue(str);
    c0_tokenizer_init(&tz, (const uint8_t *)RSTRING_PTR(str), (size_t)RSTRING_LEN(str));
    arr = rb_ary_new();
    while ((s = c0_tokenizer_next(&tz, &t)) == C0_TOKEN) {
        rb_ary_push(arr, rb_ary_new3(3, INT2NUM((int)t.type),
                                     LONG2NUM((long)t.start), LONG2NUM((long)t.end)));
    }
    if (s == C0_ERROR) {
        rb_raise(rb_eArgError, "%s",
                 tz.error == C0_ERR_UNASSIGNED
                     ? "unassigned control code"
                     : "unexpected end of input after DLE escape");
    }
    return arr;
}

static VALUE ext_table(int argc, VALUE *argv, VALUE self) {
    VALUE str, offset, headers, records;
    const uint8_t *base;
    c0_group g;
    c0_iter hi, ri;
    c0_bytes h, rec, nm;
    long ns;
    (void)self;
    rb_scan_args(argc, argv, "11", &str, &offset);
    StringValue(str);
    base = (const uint8_t *)RSTRING_PTR(str);
    g.buf = base;
    g.start = NIL_P(offset) ? 0 : (size_t)NUM2LONG(offset);
    g.end = (size_t)RSTRING_LEN(str);

    headers = rb_ary_new();
    records = rb_ary_new();
    hi = c0_group_headers(g);
    while (c0_next_header(&hi, &h)) push_span(headers, base, h);
    ri = c0_group_records(g);
    while (c0_next_record(&ri, &rec)) push_span(records, base, rec);

    nm = c0_group_name(g);
    ns = (long)(nm.ptr - base);
    return rb_ary_new3(4, LONG2NUM(ns), LONG2NUM(ns + (long)nm.len), headers, records);
}

static VALUE ext_record_fields(VALUE self, VALUE str, VALUE rstart, VALUE rend) {
    const uint8_t *base;
    long start, end;
    c0_bytes rec, f;
    c0_field_iter fi;
    VALUE arr;
    (void)self;
    StringValue(str);
    base = (const uint8_t *)RSTRING_PTR(str);
    start = NUM2LONG(rstart);
    end = NUM2LONG(rend);
    rec.ptr = base + start;
    rec.len = (size_t)(end - start);
    arr = rb_ary_new();
    fi = c0_record_fields(rec);
    while (c0_next_field(&fi, &f)) push_span(arr, base, f);
    return arr;
}

static VALUE ext_field_items(VALUE self, VALUE str, VALUE fstart, VALUE fend) {
    const uint8_t *base;
    long start, end;
    c0_bytes field, item;
    c0_list_iter li;
    VALUE arr;
    (void)self;
    StringValue(str);
    base = (const uint8_t *)RSTRING_PTR(str);
    start = NUM2LONG(fstart);
    end = NUM2LONG(fend);
    field.ptr = base + start;
    field.len = (size_t)(end - start);
    arr = rb_ary_new();
    li = c0_field_items(field);
    while (c0_next_item(&li, &item)) push_span(arr, base, item);
    return arr;
}

static VALUE ext_document(VALUE self, VALUE str) {
    const uint8_t *base;
    size_t len;
    c0_doc_iter di;
    c0_group g;
    c0_bytes nm;
    VALUE groups;
    long ns;
    (void)self;
    StringValue(str);
    base = (const uint8_t *)RSTRING_PTR(str);
    len = (size_t)RSTRING_LEN(str);
    groups = rb_ary_new();
    di = c0_doc(base, len);
    while (c0_next_group(&di, &g)) {
        rb_ary_push(groups, rb_ary_new3(2, LONG2NUM((long)g.start), LONG2NUM((long)g.end)));
    }
    nm = c0_doc_name(base, len);
    ns = (long)(nm.ptr - base);
    return rb_ary_new3(3, LONG2NUM(ns), LONG2NUM(ns + (long)nm.len), groups);
}

static VALUE ext_stream(VALUE self, VALUE str) {
    const uint8_t *base;
    c0_stream s;
    c0_block_iter bi;
    c0_bytes blk;
    VALUE blocks;
    (void)self;
    StringValue(str);
    base = (const uint8_t *)RSTRING_PTR(str);
    s = c0_stream_read(base, (size_t)RSTRING_LEN(str));
    blocks = rb_ary_new();
    bi = c0_stream_blocks(&s);
    while (c0_next_block(&bi, &blk)) push_span(blocks, base, blk);
    return rb_ary_new3(3, LONG2NUM((long)s.committed_end), s.torn ? Qtrue : Qfalse, blocks);
}

static VALUE ext_pretty_format(int argc, VALUE *argv, VALUE self) {
    VALUE str, indent;
    const char *ind;
    char *p;
    size_t outlen;
    VALUE out;
    (void)self;
    rb_scan_args(argc, argv, "11", &str, &indent);
    StringValue(str);
    ind = NIL_P(indent) ? NULL : StringValueCStr(indent);
    p = c0_pretty_format((const uint8_t *)RSTRING_PTR(str), (size_t)RSTRING_LEN(str), ind, &outlen);
    if (!p) rb_raise(rb_eNoMemError, "out of memory");
    out = rb_utf8_str_new(p, (long)outlen);
    free(p);
    return out;
}

static VALUE ext_pretty_parse(VALUE self, VALUE str) {
    uint8_t *b;
    size_t outlen;
    VALUE out;
    (void)self;
    StringValue(str);
    b = c0_pretty_parse(RSTRING_PTR(str), (size_t)RSTRING_LEN(str), &outlen);
    if (!b) rb_raise(rb_eNoMemError, "out of memory");
    out = rb_str_new((const char *)b, (long)outlen);
    free(b);
    return out;
}

void Init_c0_ext(void) {
    VALUE mC0 = rb_define_module("C0");
    VALUE mExt = rb_define_module_under(mC0, "Ext");
    rb_define_module_function(mExt, "is_assigned", ext_is_assigned, 1);
    rb_define_module_function(mExt, "canonical", ext_canonical, 1);
    rb_define_module_function(mExt, "unescape", ext_unescape, 1);
    rb_define_module_function(mExt, "tokenize", ext_tokenize, 1);
    rb_define_module_function(mExt, "table", ext_table, -1);
    rb_define_module_function(mExt, "record_fields", ext_record_fields, 3);
    rb_define_module_function(mExt, "field_items", ext_field_items, 3);
    rb_define_module_function(mExt, "document", ext_document, 1);
    rb_define_module_function(mExt, "stream", ext_stream, 1);
    rb_define_module_function(mExt, "pretty_format", ext_pretty_format, -1);
    rb_define_module_function(mExt, "pretty_parse", ext_pretty_parse, 1);
}
