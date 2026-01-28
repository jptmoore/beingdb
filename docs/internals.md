# BeingDB Internals: Encoding Scheme

This document explains how BeingDB encodes facts for storage in [Irmin Pack](https://irmin.org/).

## Storage Architecture

BeingDB uses a **2-level path architecture**:

```
["predicate_name"; "encoded_args"] → value (optional)
```

Early versions used a 3-level design that recursively traversed arguments:
```
["predicate"; "arg1"; "arg2"; "arg3"] → ""
```

This caused O(N) operations per fact. The 2-level design collapses all arguments into a single encoded path segment for O(1) lookups.

## Type-Aware Hybrid Encoding

BeingDB distinguishes between two types of arguments:

- **Atoms**: Unquoted identifiers/constants (e.g., `alice`, `project_x`, `doc123`)
- **Strings**: Quoted text literals (e.g., `"neural networks"`, `"Long text\nwith newlines"`)

This distinction comes directly from the **parser**, which preserves type information:
```ocaml
type arg_value = 
  | Atom of string      (* Unquoted: alice *)
  | String of string    (* Quoted: "Large text..." *)
```

### Storage Strategy

**Atoms** (small identifiers) → Stored **inline in the path**
**Strings** (potentially large text) → Stored in the **value field** with placeholders in path

#### Example 1: All Atoms
```
person(alice, bob)
```
- Path: `["person"; "5:alice:3:bob"]`
- Value: `""` (empty)

The encoding is length-prefixed: `5:alice` means "5 characters, then 'alice'".

#### Example 2: Mixed Atoms and Strings
```
document(doc123, "Large text with\nnewlines and special chars")
```
- Path: `["document"; "6:doc123:$:0"]`
- Value: `"Large text with\nnewlines and special chars"`

The `$:0` is a **placeholder** that references the first string in the value field.

#### Example 3: Multiple Strings
```
note(author, "First string", "Second string")
```
- Path: `["note"; "6:author:$:0:$:1"]`
- Value: `"First string\x00Second string"` (null-separated)

Strings are stored null-separated (`\x00`) in the value field, with placeholders `$:0`, `$:1`, etc.

## Encoding Format

### Path Encoding

Atoms use **length-prefixed** format:
```
N:value
```

Where `N` is the byte length and `value` is the actual content. Multiple atoms are colon-separated:
```
5:alice:3:bob:9:project_x
```

**Why length-prefixed?** It handles colons and special characters in atom values:
```
Atom "alice:admin" → "11:alice:admin"
Atom "url:port"    → "8:url:port"
```

String placeholders use a special format:
```
$:N
```

Where `N` is the index (0, 1, 2...) into the null-separated value field.

### Value Field Encoding

When strings are present, they're stored null-separated:
```
string1\x00string2\x00string3
```

Null bytes (`\x00`) are safe separators because:
- They're uncommon in text
- They're preserved correctly by Irmin
- They can't appear in valid UTF-8 middle positions

## Evolution from Heuristics

**Old approach** (removed January 2026):
```ocaml
let is_string_arg arg =
  String.contains arg '\n' ||
  String.contains arg '\t' ||
  String.contains arg '"' ||
  String.length arg > 100  (* Heuristic: fragile! *)
```

This guessed whether an argument was a "string" based on content. It was unreliable (e.g., a 101-char identifier would be treated as a string).

**New approach**:

The parser already knows the difference:
- Quoted arguments `"text"` → `Types.String`
- Unquoted arguments `alice` → `Types.Atom`

The encoding uses this type information directly:
```ocaml
match arg with
| Types.String text -> (* Use placeholder $:N *)
| Types.Atom atom   -> (* Inline with length prefix *)
```

No heuristics, no guessing.

## Related Documentation

- [Query Language](query-language.md) - Datalog syntax and semantics
- [API Documentation](api.md) - REST API endpoints
- [Deployment Guide](deployment.md) - Production setup and tuning
