read
  Read the contents of a text file. Defaults to first 2000 lines. Use offset/limit for large files.
  - path: Path to the file to read (relative or absolute)
  - offset: Line number to start reading from (1-indexed, default 1)
  - limit: Maximum number of lines to read (default 2000)

write
  Write content to a file. Creates the file if it doesn't exist, overwrites
  if it does. Automatically creates parent directories.
  - path: Path to the file to write (relative or absolute)
  - content: Content to write to the file

edit
  Edit a file by replacing exact text. The oldText must match exactly
  (including whitespace) AND must be unique in the file. Use this for
  precise, surgical edits. If the oldText appears more than once, the
  edit is refused; include more surrounding context to disambiguate.
  - path: Path to the file to edit (relative or absolute)
  - oldText: Exact text to find and replace (must match exactly, must be unique)
  - newText: New text to replace the old text with

multi_edit
  Apply several edits to the same file atomically. Each edit has the same
  uniqueness requirement as edit. Edits are applied in order against the
  running buffer; a later edit sees the result of earlier edits. If any
  edit fails, the file is not written.
  - path: Path to the file to edit
  - edits: JSON array of {"oldText": "...", "newText": "..."} objects

shell
  Execute an inferno shell command in the current working directory. Returns stdout
  and stderr. Optionally provide a timeout in seconds; if the command does not
  finish in time, it is abandoned and an error is returned.
  - command: Shell command to execute
  - timeout: Timeout in seconds (optional; 0 or omitted = no timeout)

ls
  List the contents of a directory, or stat a single file. Output is one
  entry per line: "<kind> <length> <name>" where kind is 'd' for directories
  and '-' for regular files.
  - path: Path to list (directory or file)

glob
  Recursively find files matching a filename pattern under a starting directory.
  Pattern supports a single '*' wildcard as either a prefix or a suffix (e.g.
  '*.b', 'test_*'). Results are capped at 500 entries.
  - dir: Starting directory to walk
  - pattern: Filename pattern to match (matched against basenames only)

grep
  Search for a regex pattern in a file or shell-glob of files using the
  Inferno grep command. Output is "<file>:<line>:<match>" per hit.
  - pattern: Regex pattern (passed to Inferno's grep)
  - path: File path or shell glob (e.g. '/appl/cmd/*.b')
