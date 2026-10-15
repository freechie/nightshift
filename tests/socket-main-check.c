// Fails when accept() or the daemon's socket read runs on the main thread.
//   cc -std=c11 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L -o socket-main-check tests/socket-main-check.c
#include <ctype.h>
#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum { Q_NONE = 0, Q_SOCKET, Q_MAIN, Q_OTHER };

enum { TOK_IDENT = 1, TOK_STRING, TOK_NUMBER, TOK_CHAR, TOK_PUNCT };

typedef struct {
  int kind;
  const char *start;
  int len;
  int line;
} Tok;

typedef struct {
  const char *s;
  int n;
} Name;

typedef struct {
  int start;
  int end;
} Range;

typedef struct {
  int parent;
  int queue;
  int func_id;
} Region;

typedef struct {
  Name name;
  int is_main;
  int state;
  int memo;
} Func;

typedef struct {
  Name name;
  int line;
  int region;
} Site;

typedef struct {
  Name callee;
  int region;
} Edge;

typedef struct {
  const char *file;
  char *text;
  size_t len;
  Tok *toks;
  int ntoks;
  int cap_toks;
  Name *socket_vars;
  int nsock;
  int cap_sock;
  Name *source_names;
  int *source_queues;
  int nsource;
  int cap_source;
  Region *regions;
  int nregions;
  int cap_regions;
  int *stack;
  int nstack;
  int cap_stack;
  Func *funcs;
  int nfuncs;
  int cap_funcs;
  Site *sites;
  int nsites;
  int cap_sites;
  Edge *edges;
  int nedges;
  int cap_edges;
  int unbalanced;
} Check;

static int gChecks = 0;
static int gFailures = 0;

static int name_is(Name a, const char *lit) {
  size_t n = strlen(lit);
  return a.n == (int)n && memcmp(a.s, lit, n) == 0;
}

static int name_eq(Name a, Name b) {
  return a.n == b.n && memcmp(a.s, b.s, (size_t)a.n) == 0;
}

static Name name_from(const Tok *t) {
  Name a;
  a.s = t->start;
  a.n = t->len;
  return a;
}

static int tok_is(const Tok *t, const char *lit) {
  return t->kind == TOK_IDENT && name_is(name_from(t), lit);
}

static int tok_punct(const Tok *t, char p) {
  return t->kind == TOK_PUNCT && t->len == 1 && t->start[0] == p;
}

static int tok_string(const Tok *t, const char *lit) {
  return t->kind == TOK_STRING && name_is(name_from(t), lit);
}

static void grow(void **ptr, int *cap, int need, size_t elem) {
  int next = *cap ? *cap : 32;
  while (next < need) {
    next *= 2;
  }
  void *p = realloc(*ptr, (size_t)next * elem);
  if (p == NULL) {
    perror("realloc");
    exit(2);
  }
  *ptr = p;
  *cap = next;
}

#define ADD(ptr, n, cap, val)                                                  \
  do {                                                                         \
    if ((n) >= (cap)) {                                                        \
      grow((void **)&(ptr), &(cap), (n) + 1, sizeof(*(ptr)));                  \
    }                                                                          \
    (ptr)[(n)++] = (val);                                                      \
  } while (0)

static void add_err(char *err, size_t cap, const char *line) {
  size_t used = strlen(err);
  size_t n = strlen(line);
  if (used + 1 >= cap) {
    return;
  }
  if (used + n + 1 >= cap) {
    n = cap - used - 1;
  }
  memcpy(err + used, line, n);
  err[used + n] = '\0';
}

static int lex(Check *c, char *err, size_t errcap) {
  const char *s = c->text;
  size_t n = c->len;
  size_t i = 0;
  int line = 1;
  while (i < n) {
    char ch = s[i];
    if (ch == '\n') {
      line++;
      i++;
      continue;
    }
    if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\f' || ch == '\v') {
      i++;
      continue;
    }
    if (ch == '/' && i + 1 < n && s[i + 1] == '/') {
      i += 2;
      while (i < n && s[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch == '/' && i + 1 < n && s[i + 1] == '*') {
      i += 2;
      int closed = 0;
      while (i < n) {
        if (s[i] == '\n') {
          line++;
        }
        if (s[i] == '*' && i + 1 < n && s[i + 1] == '/') {
          i += 2;
          closed = 1;
          break;
        }
        i++;
      }
      if (!closed) {
        snprintf(err, errcap, "%s:%d: unterminated comment\n", c->file, line);
        return 1;
      }
      continue;
    }
    if (ch == '"' || (ch == '@' && i + 1 < n && s[i + 1] == '"')) {
      if (ch == '@') {
        i++;
      }
      size_t start = ++i;
      int start_line = line;
      while (i < n && s[i] != '"') {
        if (s[i] == '\n') {
          line++;
        }
        if (s[i] == '\\' && i + 1 < n) {
          if (s[i + 1] == '\n') {
            line++;
          }
          i += 2;
          continue;
        }
        i++;
      }
      if (i >= n) {
        snprintf(err, errcap, "%s:%d: unterminated string\n", c->file, start_line);
        return 1;
      }
      Tok t;
      t.kind = TOK_STRING;
      t.start = s + start;
      t.len = (int)(i - start);
      t.line = start_line;
      ADD(c->toks, c->ntoks, c->cap_toks, t);
      i++;
      continue;
    }
    if (ch == '\'') {
      size_t start = i;
      int start_line = line;
      i++;
      while (i < n && s[i] != '\'') {
        if (s[i] == '\n') {
          line++;
        }
        if (s[i] == '\\' && i + 1 < n) {
          i += 2;
          continue;
        }
        i++;
      }
      if (i >= n) {
        snprintf(err, errcap, "%s:%d: unterminated character\n", c->file, start_line);
        return 1;
      }
      Tok t;
      t.kind = TOK_CHAR;
      t.start = s + start;
      t.len = (int)(i + 1 - start);
      t.line = start_line;
      ADD(c->toks, c->ntoks, c->cap_toks, t);
      i++;
      continue;
    }
    if (isdigit((unsigned char)ch)) {
      size_t start = i++;
      while (i < n && isdigit((unsigned char)s[i])) {
        i++;
      }
      Tok t;
      t.kind = TOK_NUMBER;
      t.start = s + start;
      t.len = (int)(i - start);
      t.line = line;
      ADD(c->toks, c->ntoks, c->cap_toks, t);
      continue;
    }
    if (isalpha((unsigned char)ch) || ch == '_') {
      size_t start = i++;
      while (i < n && (isalnum((unsigned char)s[i]) || s[i] == '_')) {
        i++;
      }
      Tok t;
      t.kind = TOK_IDENT;
      t.start = s + start;
      t.len = (int)(i - start);
      t.line = line;
      ADD(c->toks, c->ntoks, c->cap_toks, t);
      continue;
    }
    Tok t;
    t.kind = TOK_PUNCT;
    t.start = s + i;
    t.len = 1;
    t.line = line;
    ADD(c->toks, c->ntoks, c->cap_toks, t);
    i++;
  }
  return 0;
}

static int parse_args(const Check *c, int open, Range *args, int max_args) {
  int n = 0;
  int paren = 1;
  int brace = 0;
  int bracket = 0;
  int start = open + 1;
  for (int i = open + 1; i < c->ntoks; i++) {
    const Tok *t = &c->toks[i];
    if (brace == 0 && bracket == 0 && tok_punct(t, '(')) {
      paren++;
    } else if (brace == 0 && bracket == 0 && tok_punct(t, ')')) {
      paren--;
      if (paren == 0) {
        if (start < i && n < max_args) {
          args[n].start = start;
          args[n].end = i;
          n++;
        }
        return n;
      }
    } else if (brace == 0 && bracket == 0 && paren == 1 && tok_punct(t, ',')) {
      if (n < max_args) {
        args[n].start = start;
        args[n].end = i;
        n++;
      }
      start = i + 1;
      continue;
    }
    if (tok_punct(t, '{')) {
      brace++;
    } else if (tok_punct(t, '}')) {
      if (brace > 0) {
        brace--;
      }
    } else if (tok_punct(t, '[')) {
      bracket++;
    } else if (tok_punct(t, ']')) {
      if (bracket > 0) {
        bracket--;
      }
    }
  }
  return -1;
}

static int matching_open(const Check *c, int close_paren) {
  int depth = 0;
  for (int i = close_paren; i >= 0; i--) {
    if (tok_punct(&c->toks[i], ')')) {
      depth++;
    } else if (tok_punct(&c->toks[i], '(')) {
      depth--;
      if (depth == 0) {
        return i;
      }
    }
  }
  return -1;
}

static int is_socket_var(const Check *c, Name name) {
  for (int i = 0; i < c->nsock; i++) {
    if (name_eq(c->socket_vars[i], name)) {
      return 1;
    }
  }
  return 0;
}

static int source_queue(const Check *c, Name name) {
  for (int i = 0; i < c->nsource; i++) {
    if (name_eq(c->source_names[i], name)) {
      return c->source_queues[i];
    }
  }
  return Q_OTHER;
}

static int queue_from_range(const Check *c, Range r) {
  if (r.end <= r.start) {
    return Q_OTHER;
  }
  const Tok *first = &c->toks[r.start];
  if (tok_is(first, "dispatch_get_main_queue")) {
    return Q_MAIN;
  }
  if (tok_is(first, "dispatch_queue_create")) {
    for (int i = r.start; i < r.end; i++) {
      if (tok_string(&c->toks[i], "nightshift.socket")) {
        return Q_SOCKET;
      }
    }
    return Q_OTHER;
  }
  if (r.end - r.start == 1 && first->kind == TOK_IDENT) {
    if (is_socket_var(c, name_from(first))) {
      return Q_SOCKET;
    }
  }
  return Q_OTHER;
}

static void collect_queues(Check *c) {
  for (int i = 0; i + 3 < c->ntoks; i++) {
    if (c->toks[i].kind != TOK_IDENT || !tok_punct(&c->toks[i + 1], '=') ||
        tok_punct(&c->toks[i + 2], '=')) {
      continue;
    }
    if (!tok_is(&c->toks[i + 2], "dispatch_queue_create") ||
        !tok_punct(&c->toks[i + 3], '(')) {
      continue;
    }
    Range args[2];
    int n = parse_args(c, i + 3, args, 2);
    if (n < 1 || !tok_string(&c->toks[args[0].start], "nightshift.socket") ||
        args[0].end - args[0].start != 1) {
      continue;
    }
    ADD(c->socket_vars, c->nsock, c->cap_sock, name_from(&c->toks[i]));
  }
}

static int queue_of_block(const Check *c, int caret) {
  int paren = 0;
  int open = -1;
  for (int i = caret - 1; i >= 0; i--) {
    if (tok_punct(&c->toks[i], ')')) {
      paren++;
    } else if (tok_punct(&c->toks[i], '(')) {
      if (paren == 0) {
        open = i;
        break;
      }
      paren--;
    }
  }
  if (open < 1 || c->toks[open - 1].kind != TOK_IDENT) {
    return Q_OTHER;
  }
  const Tok *name = &c->toks[open - 1];
  if (tok_is(name, "dispatch_async") || tok_is(name, "dispatch_sync")) {
    Range args[1];
    int n = parse_args(c, open, args, 1);
    if (n < 1) {
      return Q_OTHER;
    }
    return queue_from_range(c, args[0]);
  }
  if (tok_is(name, "dispatch_source_set_event_handler") ||
      tok_is(name, "dispatch_source_set_cancel_handler")) {
    Range args[1];
    int n = parse_args(c, open, args, 1);
    if (n < 1 || args[0].end - args[0].start != 1 ||
        c->toks[args[0].start].kind != TOK_IDENT) {
      return Q_OTHER;
    }
    return source_queue(c, name_from(&c->toks[args[0].start]));
  }
  return Q_OTHER;
}

static int queue_of_region(Check *c, int region);

static int resolve_func(Check *c, int func) {
  if (c->funcs[func].is_main) {
    return Q_MAIN;
  }
  if (c->funcs[func].state == 2) {
    return c->funcs[func].memo;
  }
  if (c->funcs[func].state == 1) {
    return Q_OTHER;
  }
  c->funcs[func].state = 1;
  int saw = 0;
  int saw_main = 0;
  int saw_socket = 0;
  int saw_other = 0;
  for (int i = 0; i < c->nedges; i++) {
    if (!name_eq(c->edges[i].callee, c->funcs[func].name)) {
      continue;
    }
    int q = queue_of_region(c, c->edges[i].region);
    saw = 1;
    if (q == Q_MAIN) {
      saw_main = 1;
    } else if (q == Q_SOCKET) {
      saw_socket = 1;
    } else {
      saw_other = 1;
    }
  }
  int memo = Q_OTHER;
  if (saw && saw_socket && !saw_main && !saw_other) {
    memo = Q_SOCKET;
  } else if (saw_main) {
    memo = Q_MAIN;
  }
  c->funcs[func].state = 2;
  c->funcs[func].memo = memo;
  return memo;
}

static int queue_of_region(Check *c, int region) {
  while (region >= 0) {
    if (c->regions[region].queue != Q_NONE) {
      return c->regions[region].queue;
    }
    if (c->regions[region].func_id >= 0) {
      return resolve_func(c, c->regions[region].func_id);
    }
    region = c->regions[region].parent;
  }
  return Q_OTHER;
}

static void push_region(Check *c, int queue, int func_id) {
  Region r;
  r.parent = c->nstack > 0 ? c->stack[c->nstack - 1] : -1;
  r.queue = queue;
  r.func_id = func_id;
  ADD(c->regions, c->nregions, c->cap_regions, r);
  int id = c->nregions - 1;
  ADD(c->stack, c->nstack, c->cap_stack, id);
}

static int is_watched(const Tok *t) {
  return tok_is(t, "accept") || tok_is(t, "read") || tok_is(t, "readMessage");
}

static int definition_open(const Check *c, int ident) {
  if (ident + 1 >= c->ntoks || !tok_punct(&c->toks[ident + 1], '(')) {
    return 0;
  }
  int depth = 0;
  for (int i = ident + 1; i < c->ntoks; i++) {
    if (tok_punct(&c->toks[i], '(')) {
      depth++;
    } else if (tok_punct(&c->toks[i], ')')) {
      depth--;
      if (depth == 0) {
        return i + 1 < c->ntoks && tok_punct(&c->toks[i + 1], '{');
      }
    }
  }
  return 0;
}

static void walk(Check *c) {
  for (int i = 0; i < c->ntoks; i++) {
    const Tok *t = &c->toks[i];
    if (tok_punct(t, '{')) {
      int queue = Q_NONE;
      int func_id = -1;
      int prev = i - 1;
      if (prev >= 0 && tok_punct(&c->toks[prev], '^')) {
        queue = queue_of_block(c, prev);
      } else if (prev >= 0 && tok_punct(&c->toks[prev], ')')) {
        int open = matching_open(c, prev);
        if (open > 0 && tok_punct(&c->toks[open - 1], '^')) {
          queue = queue_of_block(c, open - 1);
        } else if (c->nstack == 0) {
          if (open > 0 && c->toks[open - 1].kind == TOK_IDENT) {
            Func f;
            memset(&f, 0, sizeof(f));
            f.name = name_from(&c->toks[open - 1]);
            f.is_main = name_is(f.name, "main");
            f.memo = Q_OTHER;
            ADD(c->funcs, c->nfuncs, c->cap_funcs, f);
            func_id = c->nfuncs - 1;
            if (f.is_main) {
              queue = Q_MAIN;
            }
          } else {
            queue = Q_MAIN;
          }
        }
      } else if (c->nstack == 0) {
        queue = Q_MAIN;
      }
      push_region(c, queue, func_id);
      continue;
    }
    if (tok_punct(t, '}')) {
      if (c->nstack == 0) {
        c->unbalanced = 1;
      } else {
        c->nstack--;
      }
      continue;
    }
    if (t->kind != TOK_IDENT || i + 1 >= c->ntoks || !tok_punct(&c->toks[i + 1], '(')) {
      continue;
    }
    if (c->nstack == 0) {
      if (is_watched(t) && !definition_open(c, i)) {
        Site site;
        site.name = name_from(t);
        site.line = t->line;
        site.region = -1;
        ADD(c->sites, c->nsites, c->cap_sites, site);
      }
      continue;
    }
    int region = c->stack[c->nstack - 1];
    if (is_watched(t)) {
      Site site;
      site.name = name_from(t);
      site.line = t->line;
      site.region = region;
      ADD(c->sites, c->nsites, c->cap_sites, site);
    }
    Edge e;
    e.callee = name_from(t);
    e.region = region;
    ADD(c->edges, c->nedges, c->cap_edges, e);
  }
  if (c->nstack != 0) {
    c->unbalanced = 1;
  }
}

static const char *queue_word(int q) {
  if (q == Q_MAIN) {
    return "the main thread";
  }
  if (q == Q_SOCKET) {
    return "nightshift.socket";
  }
  return "a queue other than nightshift.socket";
}

static int report_sites(Check *c, int trace, char *err, size_t errcap, int *sites_out) {
  if (c->unbalanced) {
    char line[256];
    snprintf(line, sizeof(line), "%s: unbalanced braces\n", c->file);
    add_err(err, errcap, line);
    return 1;
  }
  int bad = 0;
  int accepts = 0;
  for (int i = 0; i < c->nsites; i++) {
    int q = queue_of_region(c, c->sites[i].region);
    if (trace) {
      fprintf(stderr, "%s:%d: %.*s -> %s\n", c->file, c->sites[i].line,
              c->sites[i].name.n, c->sites[i].name.s, queue_word(q));
    }
    if (name_is(c->sites[i].name, "accept") && q == Q_SOCKET) {
      accepts++;
    }
    if (q != Q_SOCKET) {
      char line[512];
      snprintf(line, sizeof(line), "%s:%d: %.*s() runs on %s\n", c->file,
               c->sites[i].line, c->sites[i].name.n, c->sites[i].name.s,
               queue_word(q));
      add_err(err, errcap, line);
      bad = 1;
    }
  }
  if (accepts == 0) {
    char line[256];
    snprintf(line, sizeof(line), "%s: no accept() on nightshift.socket\n", c->file);
    add_err(err, errcap, line);
    bad = 1;
  }
  if (sites_out != NULL) {
    *sites_out = c->nsites;
  }
  return bad;
}

static void check_reset(Check *c) {
  free(c->text);
  free(c->toks);
  free(c->socket_vars);
  free(c->source_names);
  free(c->source_queues);
  free(c->regions);
  free(c->stack);
  free(c->funcs);
  free(c->sites);
  free(c->edges);
  memset(c, 0, sizeof(*c));
}

static void store_sources(Check *c) {
  for (int i = 0; i + 3 < c->ntoks; i++) {
    if (c->toks[i].kind != TOK_IDENT || !tok_punct(&c->toks[i + 1], '=') ||
        tok_punct(&c->toks[i + 2], '=')) {
      continue;
    }
    if (!tok_is(&c->toks[i + 2], "dispatch_source_create") ||
        !tok_punct(&c->toks[i + 3], '(')) {
      continue;
    }
    Range args[4];
    int n = parse_args(c, i + 3, args, 4);
    int q = Q_OTHER;
    if (n >= 4) {
      q = queue_from_range(c, args[3]);
    }
    if (c->nsource >= c->cap_source) {
      int cap = c->cap_source ? c->cap_source * 2 : 8;
      Name *names = realloc(c->source_names, (size_t)cap * sizeof(Name));
      int *queues = realloc(c->source_queues, (size_t)cap * sizeof(int));
      if (names == NULL || queues == NULL) {
        perror("realloc");
        exit(2);
      }
      c->source_names = names;
      c->source_queues = queues;
      c->cap_source = cap;
    }
    c->source_names[c->nsource] = name_from(&c->toks[i]);
    c->source_queues[c->nsource] = q;
    c->nsource++;
  }
}

static int analyze_file_text(const char *file, const char *text, size_t len, int trace,
                             char *err, size_t errcap, int *sites_out) {
  Check c;
  memset(&c, 0, sizeof(c));
  c.file = file;
  c.text = malloc(len + 1);
  if (c.text == NULL) {
    perror("malloc");
    exit(2);
  }
  memcpy(c.text, text, len);
  c.text[len] = '\0';
  c.len = len;
  err[0] = '\0';
  int failed = lex(&c, err, errcap);
  if (!failed) {
    collect_queues(&c);
    store_sources(&c);
    if (trace) {
      for (int i = 0; i < c.nsock; i++) {
        fprintf(stderr, "socket var %.*s\n", c.socket_vars[i].n, c.socket_vars[i].s);
      }
      for (int i = 0; i < c.nsource; i++) {
        fprintf(stderr, "source %.*s -> %s\n", c.source_names[i].n, c.source_names[i].s,
                queue_word(c.source_queues[i]));
      }
    }
    walk(&c);
    failed = report_sites(&c, trace, err, errcap, sites_out);
  }
  check_reset(&c);
  return failed;
}

static int count_accept_calls(const char *text, size_t len, int *line_out) {
  Check c;
  memset(&c, 0, sizeof(c));
  char err[64];
  c.file = "";
  c.text = malloc(len + 1);
  if (c.text == NULL) {
    perror("malloc");
    exit(2);
  }
  memcpy(c.text, text, len);
  c.text[len] = '\0';
  c.len = len;
  if (lex(&c, err, sizeof(err)) != 0) {
    check_reset(&c);
    return -1;
  }
  int count = 0;
  for (int i = 0; i + 1 < c.ntoks; i++) {
    if (tok_is(&c.toks[i], "accept") && tok_punct(&c.toks[i + 1], '(')) {
      if (count == 0 && line_out != NULL) {
        *line_out = c.toks[i].line;
      }
      count++;
    }
  }
  check_reset(&c);
  return count;
}

static char *read_file(const char *path, size_t *len_out) {
  FILE *f = fopen(path, "rb");
  if (f == NULL) {
    return NULL;
  }
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return NULL;
  }
  long n = ftell(f);
  if (n < 0 || n > 8 * 1024 * 1024) {
    fclose(f);
    return NULL;
  }
  if (fseek(f, 0, SEEK_SET) != 0) {
    fclose(f);
    return NULL;
  }
  char *buf = malloc((size_t)n + 1);
  if (buf == NULL) {
    fclose(f);
    return NULL;
  }
  size_t got = fread(buf, 1, (size_t)n, f);
  fclose(f);
  buf[got] = '\0';
  *len_out = got;
  return buf;
}

static int ends_with(const char *name, const char *suf) {
  size_t n = strlen(name);
  size_t m = strlen(suf);
  return n >= m && memcmp(name + n - m, suf, m) == 0;
}

static int skip_dir(const char *name) {
  return strcmp(name, ".") == 0 || strcmp(name, "..") == 0 || strcmp(name, ".git") == 0 ||
         strcmp(name, "node_modules") == 0 || strcmp(name, "dist") == 0 ||
         strcmp(name, "Nightshift.app") == 0 || strcmp(name, ".cursor") == 0;
}

static int scan_tree(const char *dir, dev_t skip_dev, ino_t skip_ino, char *err, size_t errcap) {
  DIR *d = opendir(dir);
  if (d == NULL) {
    return 1;
  }
  int bad = 0;
  struct dirent *de;
  while ((de = readdir(d)) != NULL) {
    if (skip_dir(de->d_name)) {
      continue;
    }
    char path[PATH_MAX];
    int nw = snprintf(path, sizeof(path), "%s/%s", dir, de->d_name);
    if (nw < 0 || nw >= (int)sizeof(path)) {
      continue;
    }
    struct stat st;
    if (lstat(path, &st) != 0) {
      continue;
    }
    if (S_ISLNK(st.st_mode)) {
      continue;
    }
    if (S_ISDIR(st.st_mode)) {
      if (scan_tree(path, skip_dev, skip_ino, err, errcap) != 0) {
        bad = 1;
      }
      continue;
    }
    if (!S_ISREG(st.st_mode)) {
      continue;
    }
    if (!ends_with(de->d_name, ".m") && !ends_with(de->d_name, ".h") &&
        !ends_with(de->d_name, ".c")) {
      continue;
    }
    if (st.st_dev == skip_dev && st.st_ino == skip_ino) {
      continue;
    }
    size_t len = 0;
    char *text = read_file(path, &len);
    if (text == NULL) {
      char msg[PATH_MAX + 64];
      snprintf(msg, sizeof(msg), "%s: could not read\n", path);
      add_err(err, errcap, msg);
      bad = 1;
      continue;
    }
    int line = 0;
    int n = count_accept_calls(text, len, &line);
    free(text);
    if (n < 0) {
      char msg[PATH_MAX + 64];
      snprintf(msg, sizeof(msg), "%s: could not lex\n", path);
      add_err(err, errcap, msg);
      bad = 1;
    } else if (n > 0) {
      char msg[PATH_MAX + 80];
      snprintf(msg, sizeof(msg), "%s:%d: accept() is outside nightshiftd.m\n", path, line);
      add_err(err, errcap, msg);
      bad = 1;
    }
  }
  closedir(d);
  return bad;
}

struct Fixture {
  const char *name;
  const char *text;
  int want_pass;
  const char *want_err;
};

static const char kGood[] =
    "static int readMessage(int fd, char *buf, int cap) {\n"
    "  return read(fd, buf, cap);\n"
    "}\n"
    "static void handleLine(char *line) { (void)line; }\n"
    "int main(void) {\n"
    "  const char *skip = \"accept(server, 0, 0)\";\n"
    "  (void)skip;\n"
    "  /* accept(server, 0, 0); */\n"
    "  int server = 0;\n"
    "  char buf[8];\n"
    "  dispatch_queue_t socketQueue = dispatch_queue_create(\"nightshift.socket\", 0);\n"
    "  dispatch_source_t gListener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, "
    "(uintptr_t)server, 0, socketQueue);\n"
    "  dispatch_source_set_event_handler(gListener, ^{\n"
    "    int connection = accept(server, 0, 0);\n"
    "    if (!readMessage(connection, buf, 8)) {\n"
    "      return;\n"
    "    }\n"
    "    dispatch_async(dispatch_get_main_queue(), ^{\n"
    "      handleLine(buf);\n"
    "    });\n"
    "  });\n"
    "  return 0;\n"
    "}\n";

static const char kMainSource[] =
    "static int readMessage(int fd, char *buf, int cap) {\n"
    "  return read(fd, buf, cap);\n"
    "}\n"
    "int main(void) {\n"
    "  int server = 0;\n"
    "  char buf[8];\n"
    "  dispatch_queue_t socketQueue = dispatch_queue_create(\"nightshift.socket\", 0);\n"
    "  (void)socketQueue;\n"
    "  dispatch_source_t gListener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, "
    "(uintptr_t)server, 0, dispatch_get_main_queue());\n"
    "  dispatch_source_set_event_handler(gListener, ^{\n"
    "    int connection = accept(server, 0, 0);\n"
    "    readMessage(connection, buf, 8);\n"
    "  });\n"
    "  return 0;\n"
    "}\n";

static const char kForLoop[] =
    "static int readMessage(int fd, char *buf, int cap) {\n"
    "  return read(fd, buf, cap);\n"
    "}\n"
    "int main(void) {\n"
    "  int server = 0;\n"
    "  char buf[8];\n"
    "  for (;;) {\n"
    "    int connection = accept(server, 0, 0);\n"
    "    readMessage(connection, buf, 8);\n"
    "  }\n"
    "}\n";

static const char kReadOnMain[] =
    "static int readMessage(int fd, char *buf, int cap) {\n"
    "  return read(fd, buf, cap);\n"
    "}\n"
    "int main(void) {\n"
    "  int server = 0;\n"
    "  char buf[8];\n"
    "  dispatch_queue_t socketQueue = dispatch_queue_create(\"nightshift.socket\", 0);\n"
    "  dispatch_source_t gListener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, server, 0, "
    "socketQueue);\n"
    "  dispatch_source_set_event_handler(gListener, ^{\n"
    "    int connection = accept(server, 0, 0);\n"
    "    (void)connection;\n"
    "    dispatch_async(dispatch_get_main_queue(), ^{\n"
    "      readMessage(connection, buf, 8);\n"
    "    });\n"
    "  });\n"
    "  return 0;\n"
    "}\n";

static const char kHelperGood[] =
    "static int readMessage(int fd, char *buf, int cap) {\n"
    "  return read(fd, buf, cap);\n"
    "}\n"
    "static int take(int server) {\n"
    "  return accept(server, 0, 0);\n"
    "}\n"
    "int main(void) {\n"
    "  int server = 0;\n"
    "  char buf[8];\n"
    "  dispatch_queue_t socketQueue = dispatch_queue_create(\"nightshift.socket\", 0);\n"
    "  dispatch_source_t gListener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, server, 0, "
    "socketQueue);\n"
    "  dispatch_source_set_event_handler(gListener, ^{\n"
    "    int connection = take(server);\n"
    "    readMessage(connection, buf, 8);\n"
    "  });\n"
    "  return 0;\n"
    "}\n";

static const char kHelperMain[] =
    "static int take(int server) {\n"
    "  return accept(server, 0, 0);\n"
    "}\n"
    "int main(void) {\n"
    "  int server = 0;\n"
    "  take(server);\n"
    "  return 0;\n"
    "}\n";

static const char kAsyncMain[] =
    "int main(void) {\n"
    "  int server = 0;\n"
    "  dispatch_async(dispatch_get_main_queue(), ^{\n"
    "    accept(server, 0, 0);\n"
    "  });\n"
    "  return 0;\n"
    "}\n";

static const char kWrongLabel[] =
    "static int readMessage(int fd, char *buf, int cap) {\n"
    "  return read(fd, buf, cap);\n"
    "}\n"
    "int main(void) {\n"
    "  int server = 0;\n"
    "  char buf[8];\n"
    "  dispatch_queue_t socketQueue = dispatch_queue_create(\"not-the-socket\", 0);\n"
    "  dispatch_source_t gListener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, server, 0, "
    "socketQueue);\n"
    "  dispatch_source_set_event_handler(gListener, ^{\n"
    "    accept(server, 0, 0);\n"
    "    readMessage(0, buf, 8);\n"
    "  });\n"
    "  return 0;\n"
    "}\n";

static const char kMethod[] =
    "@implementation App\n"
    "- (void)takeConnection {\n"
    "  int server = 0;\n"
    "  accept(server, 0, 0);\n"
    "}\n"
    "@end\n";

static const char kMethodHelper[] =
    "static int take(int server) {\n"
    "  return accept(server, 0, 0);\n"
    "}\n"
    "@implementation App\n"
    "- (void)takeConnection {\n"
    "  int server = 0;\n"
    "  take(server);\n"
    "}\n"
    "@end\n";

static void run_fixture(const char *name, const char *text, int want_pass, const char *want_err) {
  char err[1024];
  int sites = 0;
  int failed = analyze_file_text(name, text, strlen(text), 0, err, sizeof(err), &sites);
  gChecks++;
  if (want_pass) {
    if (failed) {
      gFailures++;
      fprintf(stderr, "fixture %s: expected pass, got %s", name, err);
    }
    return;
  }
  if (!failed || (want_err != NULL && strstr(err, want_err) == NULL)) {
    gFailures++;
    fprintf(stderr, "fixture %s: expected failure containing \"%s\", got %s", name,
            want_err != NULL ? want_err : "failure", failed ? err : "pass\n");
  }
}

static int write_text(const char *path, const char *text) {
  FILE *f = fopen(path, "w");
  if (f == NULL) {
    return 1;
  }
  if (fputs(text, f) < 0) {
    fclose(f);
    return 1;
  }
  return fclose(f) == 0 ? 0 : 1;
}

static void run_sibling_cases(void) {
  char dir[] = "/tmp/socket-main-sibling-XXXXXX";
  if (mkdtemp(dir) == NULL) {
    gChecks++;
    gFailures++;
    fprintf(stderr, "fixture siblings: mkdtemp failed\n");
    return;
  }
  char daemon[PATH_MAX];
  char other[PATH_MAX];
  snprintf(daemon, sizeof(daemon), "%s/nightshiftd.m", dir);
  snprintf(other, sizeof(other), "%s/other.m", dir);
  static const char kOther[] = "int main(void) {\n  accept(0, 0, 0);\n  return 0;\n}\n";
  if (write_text(daemon, kGood) != 0) {
    gChecks++;
    gFailures++;
    fprintf(stderr, "fixture siblings: could not write the daemon\n");
    rmdir(dir);
    return;
  }
  struct stat st;
  if (stat(daemon, &st) != 0) {
    gChecks++;
    gFailures++;
    fprintf(stderr, "fixture siblings: could not stat the daemon\n");
    unlink(daemon);
    rmdir(dir);
    return;
  }
  char err[1024];
  err[0] = '\0';
  gChecks++;
  if (scan_tree(dir, st.st_dev, st.st_ino, err, sizeof(err)) != 0) {
    gFailures++;
    fprintf(stderr, "fixture siblings-clean: expected no stray accept, got %s", err);
  }
  if (write_text(other, kOther) != 0) {
    gChecks++;
    gFailures++;
    fprintf(stderr, "fixture siblings: could not write the other file\n");
  } else {
    err[0] = '\0';
    gChecks++;
    if (scan_tree(dir, st.st_dev, st.st_ino, err, sizeof(err)) == 0 ||
        strstr(err, "other.m") == NULL) {
      gFailures++;
      fprintf(stderr, "fixture siblings-stray: expected other.m to fail, got %s",
              err[0] ? err : "pass\n");
    }
  }
  unlink(other);
  unlink(daemon);
  rmdir(dir);
}

static void run_self_test(void) {
  run_fixture("good", kGood, 1, NULL);
  run_fixture("main-queue-source", kMainSource, 0, "main thread");
  run_fixture("for-loop", kForLoop, 0, "main thread");
  run_fixture("read-on-main", kReadOnMain, 0, "readMessage() runs on the main thread");
  run_fixture("helper-socket", kHelperGood, 1, NULL);
  run_fixture("helper-main", kHelperMain, 0, "main thread");
  run_fixture("async-main", kAsyncMain, 0, "main thread");
  run_fixture("wrong-label", kWrongLabel, 0, "other than nightshift.socket");
  run_fixture("method", kMethod, 0, "main thread");
  run_fixture("method-helper", kMethodHelper, 0, "main thread");
  run_sibling_cases();
}

int main(int argc, char **argv) {
  int trace = 0;
  int siblings = 0;
  int self_only = 0;
  const char *path = NULL;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--trace") == 0) {
      trace = 1;
    } else if (strcmp(argv[i], "--siblings") == 0) {
      siblings = 1;
    } else if (strcmp(argv[i], "--self-test") == 0) {
      self_only = 1;
    } else if (argv[i][0] == '-') {
      fprintf(stderr, "unknown flag %s\n", argv[i]);
      return 2;
    } else if (path == NULL) {
      path = argv[i];
    } else {
      fprintf(stderr, "unexpected argument %s\n", argv[i]);
      return 2;
    }
  }
  run_self_test();
  if (self_only || path == NULL) {
    if (gFailures == 0) {
      printf("socket-main: %d checks passed\n", gChecks);
      return 0;
    }
    fprintf(stderr, "socket-main: %d failed\n", gFailures);
    return 1;
  }
  size_t len = 0;
  char *text = read_file(path, &len);
  if (text == NULL) {
    fprintf(stderr, "could not read %s\n", path);
    return 2;
  }
  char err[4096];
  int sites = 0;
  int failed = analyze_file_text(path, text, len, trace, err, sizeof(err), &sites);
  free(text);
  if (failed) {
    fputs(err, stderr);
    gFailures++;
  } else {
    gChecks += sites;
  }
  if (siblings) {
    struct stat target;
    if (stat(path, &target) != 0) {
      fprintf(stderr, "could not stat %s\n", path);
      return 2;
    }
    char dir[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s", path);
    char *slash = strrchr(dir, '/');
    if (slash == NULL) {
      snprintf(dir, sizeof(dir), ".");
    } else if (slash == dir) {
      slash[1] = '\0';
    } else {
      *slash = '\0';
    }
    char stray[4096];
    stray[0] = '\0';
    gChecks++;
    if (scan_tree(dir, target.st_dev, target.st_ino, stray, sizeof(stray)) != 0) {
      fputs(stray, stderr);
      gFailures++;
    }
  }
  if (gFailures == 0) {
    printf("socket-main: %d checks passed\n", gChecks);
    return 0;
  }
  fprintf(stderr, "socket-main: %d failed\n", gFailures);
  return 1;
}
