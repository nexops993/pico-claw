# Tools

ToolRegistry stores unique named tools and dispatches exact names. Brain advertises names/descriptions to provider and accepts only exact `<tool_call>{"name":"...","input":"..."}</tool_call>` response. Tool errors are returned to provider in `<tool_result>`; maximum four calls per response.

## Calculator

- Purpose: arithmetic with `+`, `-`, `*`, `/`, unary signs, decimal numbers, whitespace, and parentheses.
- Input: expression, for example `(2 + 3) * 4`.
- Output: allocated formatted number string.
- Limits: no variables/functions/exponents; rejects malformed input, division by zero, trailing text, and non-finite results.

## Filesystem

- Purpose: read/write files relative to configured base directory, currently process working directory.
- Read input: `read <relative-path>`; output is file bytes, maximum 1 MiB.
- Write input: `write <relative-path>\n<content>`; output `ok`.
- Restrictions: empty and absolute paths rejected; path components `.` and `..` rejected; leading slash/backslash rejected; writes use `resolve_beneath`.
- Limits: exact lowercase command prefix; parent directories are not automatically created; OS permissions apply. Treat workspace and symlinks according to platform security model.

## System

- Purpose: safe runtime metadata.
- Input: empty string or `info`.
- Output lines: target platform, architecture, `pico_claw=0.1.0`, and compiler Zig version.
- Restrictions: all other commands rejected. It does not invoke shell, process runner, or arbitrary system command.

No dynamic plugin loader or external tool dependency system exists.
