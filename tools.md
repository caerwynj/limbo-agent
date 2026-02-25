read
  Read the contents of a file. Supports text files and images (jpg, png,
  gif, webp). Images are sent as attachments. For text files, defaults to
  first 2000 lines. Use offset/limit for large files.
  - path: Path to the file to read (relative or absolute)
  - offset: Line number to start reading from (1-indexed)
  - limit: Maximum number of lines to read

write
  Write content to a file. Creates the file if it doesn't exist, overwrites
  if it does. Automatically creates parent directories.
  - path: Path to the file to write (relative or absolute)
  - content: Content to write to the file

edit
  Edit a file by replacing exact text. The oldText must match exactly
  (including whitespace). Use this for precise, surgical edits.
  - path: Path to the file to edit (relative or absolute)
  - oldText: Exact text to find and replace (must match exactly)
  - newText: New text to replace the old text with

bash
  Execute a bash command in the current working directory. Returns stdout
  and stderr. Optionally provide a timeout in seconds.
  - command: Bash command to execute
  - timeout: Timeout in seconds (optional, no default timeout)
