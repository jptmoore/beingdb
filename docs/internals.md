# BeingDB Pack Encoding

This document describes the encoding format used by BeingDB's Irmin Pack storage backend.

## Storage Format

Facts are stored as 2-level paths in Irmin Pack:

```
["predicate_name"; "encoded_args"] → value (optional)
```

## Encoding Rules

BeingDB encodes two types of arguments differently:

- **Atoms** (unquoted): `alice`, `project_x`, `doc123` → stored inline in path
- **Strings** (quoted): `"neural networks"`, `"Large text..."` → stored in value field with placeholder in path

### Example 1: Atoms Only

```prolog
person(alice, bob)
```

**Encoded as:**
- Path: `["person"; "5:alice:3:bob"]`
- Value: `""` (empty)

**Format:** Length-prefixed atoms separated by colons: `N:value`

### Example 2: Mixed Atoms and Strings

```prolog
document(doc123, "Large text with\nnewlines")
```

**Encoded as:**
- Path: `["document"; "6:doc123:$:0"]`
- Value: `"Large text with\nnewlines"`

**Format:** Atoms inline, strings replaced with `$:N` placeholder

### Example 3: Multiple Strings

```prolog
note(author, "First string", "Second string")
```

**Encoded as:**
- Path: `["note"; "6:author:$:0:$:1"]`
- Value: `"First string\x00Second string"`

**Format:** Null-separated (`\x00`) strings in value field

## Length Prefixes

Atoms use `N:value` format where `N` is byte length:

```
5:alice           # 5 bytes: "alice"
11:alice:admin    # 11 bytes: "alice:admin" (colon preserved)
8:url:port        # 8 bytes: "url:port"
```

This handles special characters (including colons) in atom values.

## String Placeholders

Strings use `$:N` where `N` is the index (0, 1, 2...):

```
$:0    # First string in value field
$:1    # Second string
$:2    # Third string
```

Value field stores strings null-separated: `str1\x00str2\x00str3`

