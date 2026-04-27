implement Agent;

include "sys.m";
sys: Sys;
include "draw.m";
draw: Draw;
include "bufio.m";
bufio: Bufio;
Iobuf: import bufio;
include "string.m";
str: String;
include "json.m";
json: JSON;
JValue: import json;
include "sh.m";
sh: Sh;

Agent: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

ToolCall: adt
{
	id:	string;
	name:	string;
	args:	ref JValue;
};

llmconn: string = "0";
max_context: int = 1024*64;
last_turn: int = -1;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	json = load JSON JSON->PATH;
	json->init(bufio);
	sh = load Sh Sh->PATH;

	if(argv != nil)
		argv = tl argv;
	if(argv != nil) {
		llmconn = hd argv;
	}
	else {
		llmconn = acquire_conn();
		if(llmconn == nil)
			return;
		sys->print("Acquired active session connection from clone.\n");
	}

	sys->print("Starting Agent loop on connection /n/llm/%s\n", llmconn);

	fetch_info();

	sys_prompt := load_or(list of {"/lib/llm/system.md", "./system.md"}, default_system_prompt());
	tools_md := load_or(list of {"/lib/llm/tools.md", "./tools.md"}, default_tools_md());

	if(!setup_session(sys_prompt, tools_md)) {
		sys->print("Error: failed to set up session.\n");
		return;
	}

	agent_loop(ctxt);
}

acquire_conn(): string
{
	cfd := sys->open("/n/llm/clone", Sys->OREAD);
	if(cfd == nil) {
		sys->print("Error: Could not open /n/llm/clone: %r\n");
		return nil;
	}
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0) {
		sys->print("Error reading /n/llm/clone\n");
		return nil;
	}
	return string buf[0:n];
}

fetch_info()
{
	fd := sys->open("/n/llm/info", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return;
	content := string buf[0:n];
	(nil, lines) := sys->tokenize(content, "\n");
	while(lines != nil) {
		line := hd lines;
		if(len line > 15 && line[0:15] == "context_length:") {
			val := line[15:];
			while(len val > 0 && (val[0] == ' ' || val[0] == '\t'))
				val = val[1:];
			max_context = int val;
			sys->print("Loaded context length: %d\n", max_context);
			break;
		}
		lines = tl lines;
	}
}

# Try each path in turn; return file contents, or fallback if none exist.
load_or(paths: list of string, fallback: string): string
{
	while(paths != nil) {
		(s, err) := read_all(hd paths);
		if(err == nil)
			return s;
		paths = tl paths;
	}
	return fallback;
}

setup_session(sys_prompt, tools_md: string): int
{
	if(!write_file(sys->sprint("/n/llm/%s/system", llmconn), sys_prompt)) {
		sys->print("Error writing system prompt: %r\n");
		return 0;
	}
	if(!write_file(sys->sprint("/n/llm/%s/tools", llmconn), tools_md)) {
		sys->print("Error writing tools: %r\n");
		return 0;
	}
	return 1;
}

agent_loop(ctxt: ref Draw->Context)
{
	stdin := bufio->fopen(sys->fildes(0), Sys->OREAD);

	for(;;) {
		sys->print("\n> ");
		input := stdin.gets('\n');
		if(input == nil)
			break;
		if(len input > 0 && input[len input - 1] == '\n')
			input = input[0:len input - 1];
		if(input == "exit" || input == "quit")
			break;

		# host shell escape
		if(len input > 0 && input[0] == '!') {
			cmd := input[1:];
			err := sh->system(ctxt, cmd);
			if(err != nil)
				sys->print("! %s\n", err);
			continue;
		}

		# /reset clears server-side history
		if(input == "/reset") {
			send_ctl("reset");
			# re-establish system + tools after reset
			sys_prompt := load_or(list of {"/lib/llm/system.md", "./system.md"}, default_system_prompt());
			tools_md := load_or(list of {"/lib/llm/tools.md", "./tools.md"}, default_tools_md());
			setup_session(sys_prompt, tools_md);
			last_turn = -1;
			sys->print("[reset]\n");
			continue;
		}

		# allocate user turn and write content
		ut := alloc_turn();
		if(ut < 0) {
			sys->print("Error: could not allocate turn\n");
			continue;
		}
		write_field(ut, "role", "user");
		write_field(ut, "content", input);
		last_turn = ut;
		log_transcript("user", input);

		# tool-call loop
		for(;;) {
			if(!send_ctl("send")) {
				sys->print("Error: ctl send failed: %r\n");
				break;
			}
			asst := last_turn + 1;
			finish := read_field(asst, "finish_reason");
			content := read_field(asst, "content");
			sys->print("%s\n", content);
			log_transcript("assistant", content);
			last_turn = asst;
			if(finish != "tool_calls")
				break;
			tc_text := read_field(asst, "tool_calls");
			(calls, perr) := parse_tool_calls(tc_text);
			if(perr != nil) {
				sys->print("[tool_calls parse error: %s]\n", perr);
				break;
			}
			for(cl := calls; cl != nil; cl = tl cl) {
				call := hd cl;
				sys->print("[tool] %s\n", call.name);
				result := dispatch_tool(ctxt, call.name, call.args);
				tt := alloc_turn();
				if(tt < 0) {
					sys->print("Error: could not allocate tool turn\n");
					break;
				}
				write_field(tt, "role", "tool");
				write_field(tt, "tool_call_id", call.id);
				write_field(tt, "content", result);
				last_turn = tt;
				log_transcript(sys->sprint("tool/%s", call.name), result);
			}
		}
	}
}

# --- llmfs I/O helpers --------------------------------------------------

alloc_turn(): int
{
	cfd := sys->open(sys->sprint("/n/llm/%s/messages/clone", llmconn), Sys->OREAD);
	if(cfd == nil)
		return -1;
	buf := array[16] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		return -1;
	return int string buf[0:n];
}

write_field(turn: int, field, value: string): int
{
	return write_file(sys->sprint("/n/llm/%s/messages/%d/%s", llmconn, turn, field), value);
}

read_field(turn: int, field: string): string
{
	path := sys->sprint("/n/llm/%s/messages/%d/%s", llmconn, turn, field);
	(s, nil) := read_all(path);
	return s;
}

send_ctl(cmd: string): int
{
	fd := sys->open(sys->sprint("/n/llm/%s/ctl", llmconn), Sys->OWRITE);
	if(fd == nil)
		return 0;
	buf := array of byte cmd;
	if(sys->write(fd, buf, len buf) != len buf)
		return 0;
	return 1;
}

write_file(path, content: string): int
{
	fd := sys->open(path, Sys->OWRITE | Sys->OTRUNC);
	if(fd == nil)
		fd = sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return 0;
	buf := array of byte content;
	off := 0;
	while(off < len buf) {
		n := sys->write(fd, buf[off:], len buf - off);
		if(n <= 0)
			return 0;
		off += n;
	}
	return 1;
}

read_all(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("open %s: %r", path));
	out := "";
	chunk := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, chunk, len chunk);
		if(n < 0)
			return (nil, sys->sprint("read %s: %r", path));
		if(n == 0)
			break;
		out += string chunk[0:n];
	}
	return (out, nil);
}

# --- tool-call response parsing -----------------------------------------

# Parse the JSON array we read from messages/M/tool_calls into a list of
# ToolCall.  Each element looks like:
#   {"id":"call_abc","type":"function",
#    "function":{"name":"X","arguments":"<json string>"}}
# `arguments` is a *string* (JSON-encoded); we parse it again into an
# object JValue here so the dispatcher can use get(...).
parse_tool_calls(s: string): (list of ref ToolCall, string)
{
	if(s == "")
		return (nil, "empty tool_calls");
	rb := bufio->aopen(array of byte s);
	if(rb == nil)
		return (nil, "bufio aopen failed");
	(jv, jerr) := json->readjson(rb);
	if(jerr != nil)
		return (nil, jerr);
	if(jv == nil || !jv.isarray())
		return (nil, "tool_calls not an array");
	out: list of ref ToolCall;
	pick av := jv {
	Array =>
		for(i := 0; i < len av.a; i++) {
			el := av.a[i];
			if(el == nil)
				continue;
			id := jv_get_string(el, "id");
			fn_obj := el.get("function");
			if(fn_obj == nil)
				continue;
			name := jv_get_string(fn_obj, "name");
			args_text := jv_get_string(fn_obj, "arguments");
			args: ref JValue;
			if(args_text != "") {
				ab := bufio->aopen(array of byte args_text);
				if(ab != nil) {
					(av2, aerr) := json->readjson(ab);
					if(aerr == nil)
						args = av2;
				}
			}
			if(args == nil)
				args = json->jvobject(nil);
			out = ref ToolCall(id, name, args) :: out;
		}
	}
	# reverse to original order
	rev: list of ref ToolCall;
	for(; out != nil; out = tl out)
		rev = hd out :: rev;
	return (rev, nil);
}

jv_get_string(o: ref JValue, k: string): string
{
	if(o == nil)
		return "";
	v := o.get(k);
	if(v == nil)
		return "";
	pick x := v {
	String =>	return x.s;
	}
	return "";
}

# --- tool dispatch ------------------------------------------------------

dispatch_tool(ctxt: ref Draw->Context, name: string, args: ref JValue): string
{
	case name {
	"read" =>
		path := get_string_arg(args, "path");
		offset := get_int_arg(args, "offset", 1);
		limit := get_int_arg(args, "limit", 2000);
		if(path == nil)
			return "Error: missing 'path' argument";
		return tool_read(path, offset, limit);
	"write" =>
		path := get_string_arg(args, "path");
		content := get_string_arg(args, "content");
		if(path == nil || content == nil)
			return "Error: missing 'path' or 'content' argument";
		return tool_write(path, content);
	"edit" =>
		path := get_string_arg(args, "path");
		oldText := get_string_arg(args, "oldText");
		newText := get_string_arg(args, "newText");
		if(path == nil || oldText == nil || newText == nil)
			return "Error: missing 'path', 'oldText', or 'newText' argument";
		return tool_edit(path, oldText, newText);
	"multi_edit" =>
		path := get_string_arg(args, "path");
		edits := args.get("edits");
		if(path == nil || edits == nil)
			return "Error: missing 'path' or 'edits' argument";
		return tool_multi_edit(path, edits);
	"shell" =>
		cmd := get_string_arg(args, "command");
		timeout := get_int_arg(args, "timeout", 0);
		if(cmd == nil)
			return "Error: missing 'command' argument";
		return tool_shell(ctxt, cmd, timeout);
	"ls" =>
		path := get_string_arg(args, "path");
		if(path == nil)
			return "Error: missing 'path' argument";
		return tool_ls(path);
	"glob" =>
		dir := get_string_arg(args, "dir");
		pattern := get_string_arg(args, "pattern");
		if(dir == nil || pattern == nil)
			return "Error: missing 'dir' or 'pattern' argument";
		return tool_glob(dir, pattern);
	"grep" =>
		pattern := get_string_arg(args, "pattern");
		path := get_string_arg(args, "path");
		if(pattern == nil || path == nil)
			return "Error: missing 'pattern' or 'path' argument";
		return tool_grep(ctxt, pattern, path);
	}
	return sys->sprint("Error: unknown tool %q", name);
}

get_string_arg(args: ref JValue, name: string): string
{
	if(args == nil)
		return nil;
	v := args.get(name);
	if(v == nil)
		return nil;
	pick sval := v {
	String =>	return sval.s;
	}
	return nil;
}

get_int_arg(args: ref JValue, name: string, dflt: int): int
{
	if(args == nil)
		return dflt;
	v := args.get(name);
	if(v == nil)
		return dflt;
	pick iv := v {
	Int =>		return int iv.value;
	String =>
		(i, rest) := str->toint(iv.s, 10);
		if(len rest < len iv.s)
			return i;
	}
	return dflt;
}

# --- tools --------------------------------------------------------------

tool_read(path: string, offset, limit: int): string
{
	bfd := bufio->open(path, Sys->OREAD);
	if(bfd == nil)
		return sys->sprint("Error: Could not open file %s: %r", path);
	if(offset < 1)
		offset = 1;
	if(limit <= 0)
		limit = 2000;
	out := "";
	lineno := 0;
	emitted := 0;
	for(;;) {
		line := bfd.gets('\n');
		if(line == nil)
			break;
		lineno++;
		if(lineno < offset)
			continue;
		out += line;
		emitted++;
		if(emitted >= limit)
			break;
	}
	bfd.close();
	if(lineno == 0)
		return "File is empty.";
	if(emitted == 0)
		return sys->sprint("No lines in range: file has %d lines, offset=%d.", lineno, offset);
	return out;
}

tool_write(path, content: string): string
{
	fd := sys->open(path, Sys->OWRITE | Sys->OTRUNC);
	if(fd == nil) {
		mkdirs(path);
		fd = sys->create(path, Sys->OWRITE, 8r666);
	}
	if(fd == nil)
		return sys->sprint("Error: Could not open or create file %s: %r", path);
	buf := array of byte content;
	if(sys->write(fd, buf, len buf) < 0)
		return sys->sprint("Error writing to file: %r");
	return "File written successfully.";
}

tool_edit(path, oldText, newText: string): string
{
	(content, err) := read_all(path);
	if(err != nil)
		return "Error: " + err;
	(a, b) := str->splitstrl(content, oldText);
	if(b == nil || len b == 0)
		return "Error: oldText not found in file.";
	after := b[len oldText:];
	(nil, b2) := str->splitstrl(after, oldText);
	if(b2 != nil && len b2 > 0)
		return sys->sprint("Error: oldText matches more than once in %s; provide more surrounding context to make it unique.", path);
	return tool_write(path, a + newText + after);
}

tool_multi_edit(path: string, edits: ref JValue): string
{
	if(edits == nil || !edits.isarray())
		return "Error: 'edits' must be a JSON array of {oldText, newText} objects";
	arr: array of ref JValue;
	pick ev := edits {
	Array =>
		arr = ev.a;
	}
	(content, err) := read_all(path);
	if(err != nil)
		return "Error: " + err;
	for(i := 0; i < len arr; i++) {
		e := arr[i];
		if(e == nil || !e.isobject())
			return sys->sprint("Error: edit %d is not an object", i);
		oldText := get_string_arg(e, "oldText");
		newText := get_string_arg(e, "newText");
		if(oldText == nil || newText == nil)
			return sys->sprint("Error: edit %d missing oldText or newText", i);
		(a, b) := str->splitstrl(content, oldText);
		if(b == nil || len b == 0)
			return sys->sprint("Error: edit %d oldText not found", i);
		after := b[len oldText:];
		(nil, b2) := str->splitstrl(after, oldText);
		if(b2 != nil && len b2 > 0)
			return sys->sprint("Error: edit %d oldText matches more than once; provide more context", i);
		content = a + newText + after;
	}
	return tool_write(path, content);
}

tool_shell(ctxt: ref Draw->Context, cmd: string, timeout: int): string
{
	tmp := "/tmp/sh_out_" + string sys->millisec();
	full := "{ " + cmd + " } > " + tmp + " >[2=1]";
	res: string;
	if(timeout <= 0) {
		res = sh->system(ctxt, full);
	} else {
		done := chan[1] of string;
		timer := chan[1] of int;
		spawn run_shell(ctxt, full, done);
		spawn timer_fn(timeout * 1000, timer);
		alt {
			r := <-done =>
				res = r;
			<-timer =>
				sys->remove(tmp);
				return sys->sprint("Error: command timed out after %ds", timeout);
		}
	}
	(output, rerr) := read_all(tmp);
	sys->remove(tmp);
	if(rerr != nil)
		output = "";
	if(res != nil)
		return "Exit Status: " + res + "\n" + output;
	if(len output == 0)
		return "Command executed with no output.";
	return output;
}

run_shell(ctxt: ref Draw->Context, cmd: string, done: chan of string)
{
	done <-= sh->system(ctxt, cmd);
}

timer_fn(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

tool_ls(path: string): string
{
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return sys->sprint("Error: stat %s: %r", path);
	if((d.mode & Sys->DMDIR) == 0)
		return fmt_dir_entry(d) + "\n";
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("Error: open %s: %r", path);
	out := "";
	for(;;) {
		(n, a) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < len a; i++)
			out += fmt_dir_entry(a[i]) + "\n";
	}
	if(out == "")
		return "Directory is empty.\n";
	return out;
}

fmt_dir_entry(d: Sys->Dir): string
{
	kind := "-";
	if((d.mode & Sys->DMDIR) != 0)
		kind = "d";
	return sys->sprint("%s %8bd %s", kind, d.length, d.name);
}

tool_glob(dir, pattern: string): string
{
	matches := glob_walk(dir, pattern, nil);
	if(matches == nil)
		return "No matches.\n";
	out := "";
	count := 0;
	truncated := 0;
	while(matches != nil) {
		if(count >= 500) {
			truncated = 1;
			break;
		}
		out += hd matches + "\n";
		matches = tl matches;
		count++;
	}
	if(truncated)
		out += "... (truncated at 500 results)\n";
	return out;
}

glob_walk(dir, pattern: string, acc: list of string): list of string
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return acc;
	for(;;) {
		(n, a) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < len a; i++) {
			name := a[i].name;
			full := dir;
			if(len full > 0 && full[len full - 1] != '/')
				full += "/";
			full += name;
			if((a[i].mode & Sys->DMDIR) != 0)
				acc = glob_walk(full, pattern, acc);
			else if(glob_match(pattern, name))
				acc = full :: acc;
		}
	}
	return acc;
}

glob_match(pat, name: string): int
{
	if(pat == "*")
		return 1;
	if(len pat >= 2 && pat[0] == '*') {
		suf := pat[1:];
		if(str->contains(suf, "*"))
			return pat == name;
		if(len name < len suf)
			return 0;
		return name[len name - len suf:] == suf;
	}
	if(len pat >= 2 && pat[len pat - 1] == '*') {
		pre := pat[0:len pat - 1];
		if(len name < len pre)
			return 0;
		return name[0:len pre] == pre;
	}
	return pat == name;
}

tool_grep(ctxt: ref Draw->Context, pattern, path: string): string
{
	cmd := "grep -n " + shquote(pattern) + " " + shquote(path);
	return tool_shell(ctxt, cmd, 0);
}

shquote(s: string): string
{
	out := "'";
	for(i := 0; i < len s; i++) {
		if(s[i] == '\'')
			out += "'\\''";
		else
			out += s[i:i+1];
	}
	out += "'";
	return out;
}

mkdirs(path: string): int
{
	(n, parts) := sys->tokenize(path, "/");
	if(n <= 1)
		return 1;
	dir := "";
	if(path != nil && path[0] == '/')
		dir = "/";
	while(parts != nil && tl parts != nil) {
		p := hd parts;
		if(dir == "/")
			dir += p;
		else if(dir != "")
			dir += "/" + p;
		else
			dir = p;
		(opt, d) := sys->stat(dir);
		if(opt < 0) {
			fd := sys->create(dir, Sys->OREAD, Sys->DMDIR | 8r777);
			if(fd == nil)
				return 0;
			fd = nil;
		}
		else if((d.mode & Sys->DMDIR) == 0) {
			return 0;
		}
		parts = tl parts;
	}
	return 1;
}

log_transcript(role, content: string)
{
	logfd := sys->open("transcript.log", Sys->OWRITE);
	if(logfd == nil)
		logfd = sys->create("transcript.log", Sys->OWRITE, 8r666);
	if(logfd == nil)
		return;
	sys->seek(logfd, big 0, Sys->SEEKEND);
	sys->fprint(logfd, "========== %s ==========\n%s\n\n", role, content);
}

# --- defaults -----------------------------------------------------------

default_system_prompt(): string
{
	return
		"You are an expert coding assistant connected to an Inferno OS environment.\n" +
		"You help users with coding tasks by reading files, executing commands, " +
		"editing code, and writing new files.\n\n" +
		"Use the provided tools (read, write, edit, multi_edit, shell, ls, glob, grep) " +
		"via the function-calling protocol. Do not output JSON tool blocks in your text.\n\n" +
		"Guidelines:\n" +
		"- Use 'read' to examine files before editing them.\n" +
		"- Use 'edit' for precise changes (oldText must match exactly and uniquely).\n" +
		"- Use 'write' only for new files or full rewrites.\n" +
		"- Use 'shell' for inferno shell operations not covered by the file tools.\n" +
		"- Be concise. Show file paths clearly when working with files.\n" +
		"- Documentation lives under /man.\n";
}

default_tools_md(): string
{
	return
		"# read\n" +
		"Read a text file. Returns lines [offset .. offset+limit-1] (1-indexed).\n" +
		"Defaults: offset=1, limit=2000.\n" +
		"\n" +
		"```json\n" +
		"{\"type\":\"object\"," +
		 "\"properties\":{\"path\":{\"type\":\"string\"}," +
		                  "\"offset\":{\"type\":\"integer\"}," +
		                  "\"limit\":{\"type\":\"integer\"}}," +
		 "\"required\":[\"path\"]}\n" +
		"```\n" +
		"\n" +
		"# write\n" +
		"Write content to a file, overwriting if it exists. Creates parent dirs.\n" +
		"\n" +
		"```json\n" +
		"{\"type\":\"object\"," +
		 "\"properties\":{\"path\":{\"type\":\"string\"}," +
		                  "\"content\":{\"type\":\"string\"}}," +
		 "\"required\":[\"path\",\"content\"]}\n" +
		"```\n" +
		"\n" +
		"# edit\n" +
		"Replace exact text in a file. oldText must match exactly and uniquely.\n" +
		"\n" +
		"```json\n" +
		"{\"type\":\"object\"," +
		 "\"properties\":{\"path\":{\"type\":\"string\"}," +
		                  "\"oldText\":{\"type\":\"string\"}," +
		                  "\"newText\":{\"type\":\"string\"}}," +
		 "\"required\":[\"path\",\"oldText\",\"newText\"]}\n" +
		"```\n" +
		"\n" +
		"# multi_edit\n" +
		"Apply several edits to one file atomically. Each edit has the same\n" +
		"uniqueness requirement as edit. Edits apply in order against the\n" +
		"running buffer.\n" +
		"\n" +
		"```json\n" +
		"{\"type\":\"object\"," +
		 "\"properties\":{\"path\":{\"type\":\"string\"}," +
		                  "\"edits\":{\"type\":\"array\"," +
		                            "\"items\":{\"type\":\"object\"," +
		                                       "\"properties\":{\"oldText\":{\"type\":\"string\"}," +
		                                                        "\"newText\":{\"type\":\"string\"}}," +
		                                       "\"required\":[\"oldText\",\"newText\"]}}}," +
		 "\"required\":[\"path\",\"edits\"]}\n" +
		"```\n" +
		"\n" +
		"# shell\n" +
		"Execute an inferno shell command. Returns combined stdout+stderr.\n" +
		"\n" +
		"```json\n" +
		"{\"type\":\"object\"," +
		 "\"properties\":{\"command\":{\"type\":\"string\"}," +
		                  "\"timeout\":{\"type\":\"integer\",\"description\":\"seconds; 0 = no timeout\"}}," +
		 "\"required\":[\"command\"]}\n" +
		"```\n" +
		"\n" +
		"# ls\n" +
		"List a directory or stat a single file.\n" +
		"\n" +
		"```json\n" +
		"{\"type\":\"object\"," +
		 "\"properties\":{\"path\":{\"type\":\"string\"}}," +
		 "\"required\":[\"path\"]}\n" +
		"```\n" +
		"\n" +
		"# glob\n" +
		"Recursively find files matching a basename pattern under dir.\n" +
		"Pattern supports a single '*' as prefix or suffix. Capped at 500 results.\n" +
		"\n" +
		"```json\n" +
		"{\"type\":\"object\"," +
		 "\"properties\":{\"dir\":{\"type\":\"string\"}," +
		                  "\"pattern\":{\"type\":\"string\"}}," +
		 "\"required\":[\"dir\",\"pattern\"]}\n" +
		"```\n" +
		"\n" +
		"# grep\n" +
		"Regex search via inferno grep. Output is file:line:match.\n" +
		"\n" +
		"```json\n" +
		"{\"type\":\"object\"," +
		 "\"properties\":{\"pattern\":{\"type\":\"string\"}," +
		                  "\"path\":{\"type\":\"string\"}}," +
		 "\"required\":[\"pattern\",\"path\"]}\n" +
		"```\n";
}
