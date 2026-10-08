/* Native C ABI fixture: asserts argument widths, stack arguments, pointer
 * lifetimes, callback calling convention, NULL/empty rows and cleanup. */
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct {
    char query[128];
    int row, result, bound;
    const char *params[2];
    int16_t *param_ind[2];
    void *outputs[3];
    int16_t *ind[3];
    uint16_t *len[3], *rc[3];
} handle;
static int live_handles;
static handle *make(void) { ++live_handles; return calloc(1, sizeof(handle)); }
static void release(void *h) { assert(h && live_handles > 0); --live_handles; free(h); }
int sql_fixture_live_handles(void) { return live_handles; }
static const char *values[] = {"hello", NULL, ""};
static unsigned long lengths[] = {5, 0, 0};
static const char *names[] = {"value", "null_value", "empty_value"};

void *mysql_init(void *unused) { return make(); }
int mysql_options(void *h, int option, void *value) {
    assert(option == 0 || option == 8);
    assert(*(unsigned int *)value == (option == 0 ? 5u : 0u)); return 0;
}
void *mysql_real_connect(void *h, const char *host, const char *user,
                        const char *pass, const char *db, unsigned int port,
                        const char *socket, unsigned long flags) {
    assert(!socket && !flags && port == 3306);
    assert(!strcmp(user, "user") && !strcmp(pass, "password") && !strcmp(db, "db"));
    return strcmp(host, "fail") ? h : NULL;
}
const char *mysql_error(void *h) { return "fixture MySQL error"; }
void mysql_close(void *h) { release(h); }
int mysql_set_character_set(void *h, const char *s) { assert(!strcmp(s, "utf8mb4")); return 0; }
int mysql_real_query(handle *h, const char *q, unsigned long n) {
    assert(n == strlen(q)); snprintf(h->query, sizeof(h->query), "%s", q);
    h->row = h->result = 0; return !strcmp(q, "ERROR");
}
void *mysql_store_result(handle *h) { return !strncmp(h->query, "SELECT", 6) ? h : NULL; }
unsigned int mysql_field_count(handle *h) { return !strncmp(h->query, "SELECT", 6) ? 3 : 0; }
unsigned int mysql_num_fields(void *h) { return 3; }
const char **mysql_fetch_row(handle *h) { return h->row++ == 0 ? values : NULL; }
unsigned long *mysql_fetch_lengths(void *h) { return lengths; }
void mysql_free_result(void *h) {}
uint64_t mysql_affected_rows(void *h) { return 1; }
unsigned int mysql_errno(void *h) { return 0; }
void *mysql_fetch_field_direct(void *h, unsigned int n) { assert(n < 3); return &names[n]; }
int mysql_next_result(handle *h) { return !strcmp(h->query, "SELECT multiple") && h->result++ == 0 ? 0 : -1; }

typedef int (*errfn)(void *, int, int, int, const char *, const char *);
typedef int (*msgfn)(void *, int, int, int, const char *, const char *, const char *, int);
static errfn err;
static msgfn msg;
void *dberrhandle(errfn f) { err = f; return NULL; }
void *dbmsghandle(msgfn f) { msg = f; return NULL; }
int dbinit(void) { err = NULL; return 1; }
void *dblogin(void) { return make(); }
void dbloginfree(void *p) { release(p); }
int dbsetlname(void *l, const char *s, int which) { assert(which == 2 || which == 3 || which == 10); return 1; }
int dbsetlversion(void *l, unsigned char version) { assert(version == 8); return 1; }
void *tdsdbopen(void *l, const char *server, int microsoft) {
    assert(microsoft == 1 && err && msg);
    if (!strcmp(server, "fail")) {
        assert(err(NULL, 16, 20002, 0, "fixture login failure", "") == 2); return NULL;
    }
    return make();
}
void dbclose(void *p) { release(p); }
int dbuse(void *p, const char *database) { assert(!strcmp(database, "db")); return 1; }
int dbcmd(handle *h, const char *q) { snprintf(h->query, sizeof(h->query), "%s", q); h->result = h->row = 0; return 1; }
int dbsqlexec(handle *h) {
    if (!strcmp(h->query, "ERROR")) {
        assert(msg(h, 102, 1, 16, "fixture SQL Server syntax error", "server", "proc", 1) == 0);
        return 0;
    }
    /* Informational server messages must not become query failures. */
    assert(msg(h, 1, 1, 0, "fixture info", "server", "proc", 1) == 0); return 1;
}
int dbresults(handle *h) { return h->result++ < (!strcmp(h->query, "SELECT multiple") ? 2 : 1) ? 1 : 2; }
int dbnumcols(handle *h) { return !strncmp(h->query, "SELECT", 6) ? 3 : 0; }
const char *dbcolname(void *h, int col) { assert(col >= 1 && col <= 3); return names[col - 1]; }
int dbnextrow(handle *h) { return h->row++ == 0 ? -1 : -2; }
const char *dbdata(void *h, int col) { return values[col - 1]; }
int dbdatlen(void *h, int col) { return lengths[col - 1]; }
int dbcoltype(void *h, int col) { return 47; }
int dbconvert(void *h, int type, const char *src, int n, int desttype, char *dest, int capacity) {
    assert(type == 47 && desttype == 47 && capacity >= n); memcpy(dest, src, n); return n;
}
int dbcancel(void *h) { return 1; }
int dbcount(void *h) { return 1; }

/* OCI uses 16- and 32-bit C output slots even on a 64-bit host. */
int OCIEnvNlsCreate(void **env, uint32_t mode, void *ctx, void *a, void *r,
                    void *f, size_t extra, void **user, uint16_t cs, uint16_t ncs) {
    assert(!mode && !ctx && !a && !r && !f && !extra && !user && cs == 873 && ncs == 873);
    *env = make(); return 0;
}
int OCIHandleAlloc(void *parent, void **out, uint32_t type, size_t extra, void **user) {
    assert(parent && type == 2 && !extra && !user); *out = make(); return 0;
}
int OCIHandleFree(void *h, uint32_t type) { assert(type == 1 || type == 2); release(h); return 0; }
int OCILogon2(void *env, void *errh, void **svc, const char *user, uint32_t un,
              const char *pass, uint32_t pn, const char *db, uint32_t dn, uint32_t mode) {
    assert(env && errh && un == strlen(user) && pn == strlen(pass) && dn == strlen(db) && !mode);
    if (!strcmp(db, "fail")) return -1;
    *svc = make(); return 0;
}
int OCILogoff(void *svc, void *errh) { release(svc); return 0; }
int OCIErrorGet(void *h, uint32_t record, void *state, int32_t *code, char *buf, uint32_t size, uint32_t type) {
    assert(record == 1 && type == 2); *code = 42; snprintf(buf, size, "fixture Oracle error"); return 0;
}
int OCIStmtPrepare2(void *svc, handle **stmt, void *errh, const char *sql, uint32_t len,
                    void *key, uint32_t keylen, uint32_t lang, uint32_t mode) {
    assert(len == strlen(sql) && !key && !keylen && lang == 1 && !mode);
    *stmt = make(); snprintf((*stmt)->query, sizeof((*stmt)->query), "%s", sql); return 0;
}
int OCIStmtRelease(void *s, void *errh, void *key, uint32_t len, uint32_t mode) {
    assert(!key && !len && !mode); release(s); return 0;
}
int OCIBindByPos(handle *s, void **bind, void *errh, uint32_t pos, void *value, int32_t size,
                 uint16_t type, int16_t *ind, uint16_t *len, uint16_t *rc, uint32_t max,
                 uint32_t *current, uint32_t mode) {
    assert(pos >= 1 && pos <= 2 && size > 0 && type == 5 && !len && !rc && !max && !current && !mode);
    s->bound++; s->params[pos - 1] = value; s->param_ind[pos - 1] = ind; *bind = s; return 0;
}
int OCIStmtExecute(void *svc, handle *s, void *errh, uint32_t iters, uint32_t off,
                   void *in, void *out, uint32_t mode) {
    assert(!off && !in && !out);
    assert(iters == (!strncmp(s->query, "SELECT", 6) ? 0u : 1u));
    assert(mode == 0 || mode == 32);
    if (!strcmp(s->query, "SELECT bound")) {
        assert(s->bound == 2 && *s->param_ind[0] == 0 && *s->param_ind[1] == -1);
    }
    return !strcmp(s->query, "ERROR") ? -1 : 0;
}
int OCIAttrGet(void *h, uint32_t type, void *out, uint32_t *size, uint32_t attr, void *errh) {
    handle *s = h;
    if (type == 4 && attr == 24) *(uint16_t *)out = !strncmp(s->query, "SELECT", 6) ? 1 : 4;
    else if (type == 4 && attr == 18) *(uint32_t *)out = !strcmp(s->query, "SELECT too_wide") ? 1000000 : 3;
    else if (type == 4 && attr == 9) *(uint32_t *)out = 1;
    else if (type == 53 && attr == 4) { *(const char **)out = names[s->row]; *size = strlen(names[s->row]); }
    else if (type == 53 && attr == 2) *(uint16_t *)out = 1;
    else abort();
    return 0;
}
int OCIParamGet(void *s, uint32_t type, void *errh, handle **out, uint32_t pos) {
    assert(type == 4 && pos >= 1 && pos <= 3); *out = make(); (*out)->row = pos - 1; return 0;
}
int OCIDescriptorFree(void *p, uint32_t type) { assert(type == 53); release(p); return 0; }
int OCIDefineByPos(handle *s, void **def, void *errh, uint32_t pos, void *value,
                   int32_t capacity, uint16_t type, int16_t *ind, uint16_t *len,
                   uint16_t *rc, uint32_t mode) {
    assert(pos >= 1 && pos <= 3 && capacity == 32767 && type == 1 && !mode);
    --pos; s->outputs[pos] = value; s->ind[pos] = ind; s->len[pos] = len; s->rc[pos] = rc; *def = s; return 0;
}
int OCIStmtFetch2(handle *s, void *errh, uint32_t count, uint16_t direction, int32_t off, uint32_t mode) {
    assert(count == 1 && direction == 2 && !off && !mode);
    if (s->row++) return 100;
    for (int i = 0; i < 3; ++i) {
        const char *v = values[i];
        if (s->bound && i < 2) v = *s->param_ind[i] == -1 ? NULL : s->params[i];
        *s->ind[i] = v ? 0 : -1; *s->len[i] = v ? strlen(v) : 0; *s->rc[i] = 0;
        if (v) memcpy(s->outputs[i], v, strlen(v));
    }
    if (!strcmp(s->query, "SELECT truncated")) { *s->ind[0] = 200; *s->rc[0] = 1406; return 1; }
    return 0;
}
int OCITransCommit(void *svc, void *errh, uint32_t flags) { assert(!flags); return 0; }
int OCITransRollback(void *svc, void *errh, uint32_t flags) { assert(!flags); return 0; }
