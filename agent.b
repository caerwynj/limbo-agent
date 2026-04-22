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

Message: adt
{
	role: string;
	content: string;
};

llmconn: string = "0";
max_context: int = 1024*64;

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
		cfd := sys->open("/n/llm/clone", Sys->OREAD);
		if(cfd == nil) {
			sys->print("Error: Could not open /n/llm/clone: %r\n");
			return;
		}
		buf := array[32] of byte;
		n := sys->read(cfd, buf, len buf);
		if(n > 0)
			llmconn = string buf[0:n];
		else {
			sys->print("Error reading /n/llm/clone\n");
			return;
		}
		sys->print("Acquired active session connection from clone.\n");
	}

	sys->print("Starting Agent loop on connection /n/llm/%s\n", llmconn);

	fetch_info();

	sys_prompt := build_system_prompt();
	agent_loop(ctxt, sys_prompt);
}

fetch_info()
{
	fd := sys->open("/n/llm/info", Sys->OREAD);
	if(fd == nil)
		return;

	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n > 0) {
		content := string buf[0:n];
		(num_lines, lines) := sys->tokenize(content, "\n");
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
}

build_system_prompt(): string
{
	sys->print("Reading system.md...\n");
	sfd := sys->open("/lib/llm/system.md", Sys->OREAD);
	if(sfd == nil)
		sfd = sys->open("./system.md", Sys->OREAD);
	
	system_prompt := "";
	if(sfd != nil) {
		buf := array[8192] of byte;
		n := sys->read(sfd, buf, len buf);
		if(n > 0)
			system_prompt = string buf[0:n];
	} else {
		system_prompt = "You are a helpful AI assistant connected to an Inferno OS environment. " + "You have access to the following tools to accomplish the user's goals. " + "To invoke a tool, you MUST output a raw JSON block wrapped in exactly ```json and ```.\n" + "Example:\n```json\n{\n  \"name\": \"shell\",\n  \"arguments\": {\n    \"command\": \"ls -la\"\n  }\n}\n```\n\n";
	}

	sys->print("Reading tools.md...\n");
	tfd := sys->open("/lib/llm/tools.md", Sys->OREAD);
	if(tfd == nil)
		tfd = sys->open("./tools.md", Sys->OREAD);
	
	tools_doc := "Available tools:\n\n";

	if(tfd != nil) {
		buf := array[8192] of byte;
		n := sys->read(tfd, buf, len buf);
		if(n > 0)
			tools_doc += string buf[0:n];
	}
	else {
		tools_doc += "read, write, edit, shell";
	}

	return system_prompt + "\n" + tools_doc;
}

agent_loop(ctxt: ref Draw->Context, sys_prompt: string)
{
	stdin := bufio->fopen(sys->fildes(0), Sys->OREAD);
	history: list of ref Message = nil;

	for(;;) {
		sys->print("\n> ");
		input := stdin.gets('\n');
		if(input == nil)
			break;
		if(len input > 0 && input[len input - 1] == '\n')
			input = input[0:len input - 1];
		if(input == "exit" || input == "quit")
			break;

		if(len input > 0 && input[0] == '!') {
			cmd := input[1:];
			err := sh->system(ctxt, cmd);
			if(err != nil)
				sys->print("! %s\n", err);
			continue;
		}

		history = append_msg(history, ref Message("user", input));

		for(;;) {
			sys->print("[Trace] Enforcing context limit...\n");
			history = enforce_context_limit(sys_prompt, history);
			sys->print("[Trace] Building prompt...\n");
			prompt := build_prompt(sys_prompt, history);

			sys->print("[Trace] Sending reset to ctl...\n");
			send_reset();
			sys->print("[Trace] Opening data file for writing...\n");
			fd := sys->open(sys->sprint("/n/llm/%s/data", llmconn), Sys->OWRITE);
			if(fd != nil) {
				sys->print("[Trace] Writing prompt to data via bufio...\n");
				bfd := bufio->fopen(fd, Sys->OWRITE);
				if(bfd != nil) {
					bfd.puts(prompt);
					bfd.flush();
					bfd.close();
				}
				fd = nil;
				sys->print("[Trace] Logging transcript...\n");
				log_transcript(prompt);
			}
			else {
				sys->print("Error writing to data file: %r\n");
				break;
			}

			sys->print("[Trace] Pumping assistant...\n");
			(tool_called, asst_msg, tool_res) := pump_assistant(ctxt);
			sys->print("[Trace] Pump completed. tool_called: %d\n", tool_called);
			
			if(len asst_msg > 0)
				history = append_msg(history, ref Message("assistant", asst_msg));

			if(!tool_called)
				break;

			sys->print("[Trace] Appending tool result to user history...\n");
			history = append_msg(history, ref Message("user", "\n<tool_result>\n" + tool_res + "\n</tool_result>\n"));
		}
	}
}

pump_assistant(ctxt: ref Draw->Context): (int, string, string)
{
	afd := bufio->fopen(sys->open(sys->sprint("/n/llm/%s/data", llmconn), Sys->OREAD), Sys->OREAD);
	if(afd == nil) {
		sys->print("Error: Could not open assistant output file: %r\n");
		return (0, "", "");
	}

	capture_mode := 0;
	json_buf := "";
	full_msg := "";

	for(;;) {
		buf := array[1] of byte;
		n := afd.read(buf, 1);
		if(n <= 0)
			break;

		charstr := string buf[0:1];
		full_msg += charstr;

		if(capture_mode) {
			json_buf += charstr;

			# Check for ending ``` (or </tool_call> as a fallback)
			if(len json_buf >= 3 && json_buf[len json_buf - 3:] == "```") {
				capture_mode = 0;
				json_body := json_buf[0:len json_buf - 3];
				afd.close();
				afd = nil;
				res := execute_tool(ctxt, json_body);
				return (1, full_msg, res);
			}
			else if(len json_buf >= 12 && json_buf[len json_buf - 12:] == "</tool_call>") {
				capture_mode = 0;
				json_body := json_buf[0:len json_buf - 12];
				afd.close();
				afd = nil;
				res := execute_tool(ctxt, json_body);
				return (1, full_msg, res);
			}
		}
		else {
			json_buf += charstr;
			if(len json_buf > 15)
				json_buf = json_buf[1:];

			if(len json_buf >= 7 && json_buf[len json_buf - 7:] == "```json") {
				capture_mode = 1;
				json_buf = "";
			}
			else if(len json_buf >= 11 && json_buf[len json_buf - 11:] == "<tool_call>") {
				capture_mode = 1;
				json_buf = "";
			}
			else if(len json_buf >= 12 && json_buf[len json_buf - 12:] == "```tool_call") {
				capture_mode = 1;
				json_buf = "";
			}

			if(!capture_mode) {
				sys->print("%s", charstr);
			}
		}
	}
	afd.close();
	afd = nil;
	return (0, full_msg, "");
}

execute_tool(ctxt: ref Draw->Context, tool_json: string): string
{
	sys->print("\n[Executing tool call]\n");
	b := bufio->aopen(array of byte tool_json);
	if(b == nil) {
		return "Failed to open JSON buffer";
	}

	(jv, err) := json->readjson(b);
	if(jv == nil) {
		return sys->sprint("JSON parsing failed: %s", err);
	}

	name_val := jv.get("name");
	if(name_val == nil ||!name_val.isstring()) {
		return "Tool call missing valid 'name' field";
	}
	name := "";
	pick v := name_val {
	String =>
		name = v.s;
	}

	args_val := jv.get("arguments");
	if(args_val == nil ||!args_val.isobject()) {
		return "Tool call missing 'arguments' object";
	}

	result := "";

	case name {
	"read" =>
		path := get_string_arg(args_val, "path");
		offset := get_int_arg(args_val, "offset", 1);
		limit := get_int_arg(args_val, "limit", 2000);
		if(path == nil)
			result = "Error: missing 'path' argument";
		else
			result = tool_read(path, offset, limit);
	"write" =>
		path := get_string_arg(args_val, "path");
		content := get_string_arg(args_val, "content");
		if(path == nil || content == nil)
			result = "Error: missing 'path' or 'content' argument";
		else
			result = tool_write(path, content);
	"edit" =>
		path := get_string_arg(args_val, "path");
		oldText := get_string_arg(args_val, "oldText");
		newText := get_string_arg(args_val, "newText");
		if(path == nil || oldText == nil || newText == nil)
			result = "Error: missing 'path', 'oldText', or 'newText' argument";
		else
			result = tool_edit(path, oldText, newText);
	"multi_edit" =>
		path := get_string_arg(args_val, "path");
		edits := args_val.get("edits");
		if(path == nil || edits == nil)
			result = "Error: missing 'path' or 'edits' argument";
		else
			result = tool_multi_edit(path, edits);
	"shell" =>
		cmd := get_string_arg(args_val, "command");
		timeout := get_int_arg(args_val, "timeout", 0);
		if(cmd == nil)
			result = "Error: missing 'command' argument";
		else
			result = tool_shell(ctxt, cmd, timeout);
	"ls" =>
		path := get_string_arg(args_val, "path");
		if(path == nil)
			result = "Error: missing 'path' argument";
		else
			result = tool_ls(path);
	"glob" =>
		dir := get_string_arg(args_val, "dir");
		pattern := get_string_arg(args_val, "pattern");
		if(dir == nil || pattern == nil)
			result = "Error: missing 'dir' or 'pattern' argument";
		else
			result = tool_glob(dir, pattern);
	"grep" =>
		pattern := get_string_arg(args_val, "pattern");
		path := get_string_arg(args_val, "path");
		if(pattern == nil || path == nil)
			result = "Error: missing 'pattern' or 'path' argument";
		else
			result = tool_grep(ctxt, pattern, path);
	* =>
		result = sys->sprint("Error: Unknown tool '%s'", name);
	}

	sys->print("Result:\n%s\n", result);
	return result;
}

get_string_arg(args: ref JValue, name: string): string
{
	v := args.get(name);
	if(v != nil && v.isstring()) {
		pick sval := v {
		String =>
			return sval.s;
		}
	}
	return nil;
}

get_int_arg(args: ref JValue, name: string, dflt: int): int
{
	v := args.get(name);
	if(v == nil)
		return dflt;
	if(v.isint()) {
		pick iv := v {
		Int =>
			return int iv.value;
		}
	}
	if(v.isstring()) {
		pick sv := v {
		String =>
			(i, rest) := str->toint(sv.s, 10);
			if(len rest < len sv.s)
				return i;
		}
	}
	return dflt;
}

read_all(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("Could not open %s: %r", path));
	out := "";
	chunk := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, chunk, len chunk);
		if(n < 0)
			return (nil, sys->sprint("read error: %r"));
		if(n == 0)
			break;
		out += string chunk[0:n];
	}
	return (out, nil);
}

tool_read(path: string, offset: int, limit: int): string
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

tool_write(path: string, content: string): string
{
	fd := sys->open(path, Sys->OWRITE | Sys->OTRUNC);
	if(fd == nil) {
		mkdirs(path);
		fd = sys->create(path, Sys->OWRITE, 8r666);
	}
	if(fd == nil)
		return sys->sprint("Error: Could not open or create file %s: %r", path);

	buf := array of byte content;
	n := sys->write(fd, buf, len buf);
	if(n < 0)
		return sys->sprint("Error writing to file: %r");

	return "File written successfully.";
}

tool_edit(path: string, oldText: string, newText: string): string
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

	new_content := a + newText + after;

	return tool_write(path, new_content);
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
	sys->print("Running shell command: %s\n", cmd);

	tmp := "/tmp/sh_out_" + string sys->millisec();
	full := "{ " + cmd + " } > " + tmp + " >[2=1]";

	res: string;
	if(timeout <= 0) {
		res = sh->system(ctxt, full);
	}
	else {
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
	r := sh->system(ctxt, cmd);
	done <-= r;
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

tool_glob(dir: string, pattern: string): string
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

glob_walk(dir: string, pattern: string, acc: list of string): list of string
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

glob_match(pat: string, name: string): int
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

tool_grep(ctxt: ref Draw->Context, pattern: string, path: string): string
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

append_msg(l: list of ref Message, m: ref Message): list of ref Message
{
	if(l == nil)
		return m::nil;
	return hd l::append_msg(tl l, m);
}

send_reset()
{
	cfd := sys->open(sys->sprint("/n/llm/%s/ctl", llmconn), Sys->OWRITE);
	if(cfd != nil)
		sys->fprint(cfd, "reset");
}

build_prompt(sys_prompt: string, history: list of ref Message): string
{
	p := "<start_of_turn>user\n" + sys_prompt + "\n";

	in_user := 1;

	q := history;
	while(q != nil) {
		m := hd q;
		role := m.role;
		
		if (role == "user") {
			if (!in_user) {
				p += "<start_of_turn>user\n";
				in_user = 1;
			}
			p += m.content + "\n";
		} else {
			if (in_user) {
				p += "<end_of_turn>\n";
				in_user = 0;
			}
			p += "<start_of_turn>model\n" + m.content + "<end_of_turn>\n";
		}
		q = tl q;
	}
	
	if (in_user) {
		p += "<end_of_turn>\n";
	}

	p += "<start_of_turn>model\n";
	return p;
}

# 1 char roughly 0.3 tokens
enforce_context_limit(sys_prompt: string, history: list of ref Message): list of ref Message
{
	for(;;) {
		total_len := len sys_prompt;

		q := history;
		while(q != nil) {
			m := hd q;
			total_len += len m.role + len m.content + 40;
			# some buffer for formatting
			q = tl q;
		}

		est_tokens := total_len / 3;
		if(est_tokens < max_context || history == nil)
			break;

		# pop oldest history element
		history = tl history;
	}
	return history;
}

log_transcript(prompt: string)
{
	logfd := sys->open("transcript.log", Sys->OWRITE);
	if(logfd == nil)
		logfd = sys->create("transcript.log", Sys->OWRITE, 8r666);
	if(logfd != nil) {
		sys->seek(logfd, big 0, Sys->SEEKEND);
		# We can use the current time if we load Daytime or just a separator
		sys->fprint(logfd, "========== PROMPT ==========\n%s\n============================\n\n", prompt);
	}
}
