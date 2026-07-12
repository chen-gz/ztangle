# ztangle (Zig Literate Notebook Utility)

`ztangle` is a general-purpose, standalone Zig command-line tool designed to parse MDX and Markdown files, extract and compile runnable Zig code blocks, capture their execution output, and insert the results back into the document in-place.

It works just like a Jupyter notebook, enabling idempotent updates when code blocks or dependencies are changed.

The name **`ztangle`** is inspired by Donald Knuth's concept of Literate Programming, where "tangling" is the process of generating runnable code from a document.

---

## Features

1. **Notebook Behavior**: Supports placing standard placeholder tags (`{{zig code result holder}}` or `<!-- zig-result-start --><!-- zig-result-end -->`) immediately after ` ```zig ` blocks. On execution, it runs the code and wraps the output in start/end comments. Subsequent runs update this block in-place.
2. **O(1) Compilation & Execution**: Compiles and executes all code blocks in the document exactly **once** using unified program generation and output partitioning.
3. **Flat Notebook State (Variable Sharing)**: Code blocks accumulate sequentially. Variables and state initialized in earlier blocks are completely accessible by downstream blocks.
4. **Hiding Setup Blocks**: Supports wrapping setup blocks in HTML comments `<!-- ... -->` or `<div style={{ display: 'none' }}>...</div>` to keep them active in execution while hiding them from the rendered blog layout in Astro/MDX.
5. **Flexible Dependency Declarations**: Dependencies (like `zig_ml`) can be declared dynamically using either frontmatter YAML metadata or command-line flags.
6. **Flexible Build Flags**: Compilation flags can also be specified in the frontmatter or CLI (e.g., `-lc -framework Accelerate` for macOS acceleration).
7. **Complete Output Capture**: Captures both standard output and standard error (e.g. `std.debug.print` calls) from execution.
8. **Inline Error Reporting**: If a code block fails to compile or run, the error trace or panic stack trace is written into the result block in the MDX file, making it easy to debug inside your editor.

---

## Build & Install

### Prerequisites
- **Zig Compiler**: Version `0.16.0` (or compatible).

### Building from Source
To compile `ztangle` as a release build:
```bash
zig build -Doptimize=ReleaseSafe
```
The compiled binary will be placed at `zig-out/bin/ztangle`.

### Cleaning Build Caches
If you need to clear the build caches and start fresh:
```bash
rm -rf .zig-cache zig-out
```

---

## Usage

### 1. Declare Dependencies in MDX Frontmatter

At the beginning of your MDX or Markdown file, add `zig_dependencies` and `zig_flags` to the YAML frontmatter:

```yaml
---
title: "Transformer in Zig"
zig_dependencies:
  zig_ml: "../znn"
zig_flags: "-lc -framework Accelerate"
---
```

*Note: Relative paths in the frontmatter are resolved relative to the folder containing the MDX file.*

### 2. Add Code Blocks & Placeholders

Write your Zig code blocks followed by a placeholder. For example:

```markdown
Here is some inline calculation:

```zig
const std = @import("std");
pub fn main() !void {
    std.debug.print("Hello, world! 2 + 2 = {}\n", .{2 + 2});
}
```
{{zig code result holder}}
```

### 3. Run Tangle

Run the binary on your MDX file:

```bash
./zig-out/bin/ztangle path/to/your/blog.mdx
```

This will run the Zig code, replace the placeholder, and update it to:

```markdown
Here is some inline calculation:

```zig
const std = @import("std");
pub fn main() !void {
    std.debug.print("Hello, world! 2 + 2 = {}\n", .{2 + 2});
}
```

<!-- zig-result-start -->
```
Hello, world! 2 + 2 = 4
```
<!-- zig-result-end -->
```

Subsequent runs will update the content between `<!-- zig-result-start -->` and `<!-- zig-result-end -->` automatically.

---

## CLI Options

You can also override or append dependencies and flags directly via the command line:

```bash
./zig-out/bin/ztangle --dep zig_ml=../another-znn --flag "-lc" input.mdx
```

To preserve the compiled Zig source file in `.temp/` for debugging:

```bash
./zig-out/bin/ztangle --keep input.mdx
```
