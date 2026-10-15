# Print file, line, and key name from a git grep -n line. Never print the line.
{
  file = $0
  sub(/:.*/, "", file)
  rest = substr($0, length(file) + 2)
  line = rest
  sub(/:.*/, "", line)
  text = substr(rest, length(line) + 2)
  key = ""
  if (match(text, /^[ \t]*(export[ \t]+)?["']?[A-Za-z_][A-Za-z0-9_]*["']?[ \t]*[=:]/)) {
    key = substr(text, RSTART, RLENGTH)
    sub(/^[ \t]*(export[ \t]+)?["']?/, "", key)
    sub(/["']?[ \t]*[=:]$/, "", key)
  }
  if (key == "") {
    printf "  %s:%s\n", file, line
  } else {
    printf "  %s:%s (%s)\n", file, line, key
  }
}
