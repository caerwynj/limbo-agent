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
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

llmconn: string = "0";

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	json = load JSON JSON->PATH;
	json->init(bufio);
	sh = load Sh Sh->PATH;
	

	if(argv != nil) argv = tl argv;
	if(argv != nil) {
		llmconn = hd argv;
	} else {
		cfd := sys->open("/n/llm/clone", Sys->OREAD);
		if(cfd == nil) {
			sys->print("Error: Could not open /n/llm/clone: %r\n");
			return;
		}
		buf := array[32] of byte;
		n := sys->read(cfd, buf, len buf);
		if(n > 0) llmconn = string buf[0:n];
		else {
			sys->print("Error reading /n/llm/clone\n");
			return;
		}
		sys->print("Acquired active session connection from clone.\n");
	}

	sys->print("Starting Agent loop on connection /n/llm/%s\n", llmconn);
	
	push_system_prompt();
	agent_loop(ctxt);
}

push_system_prompt()
{
	fd := sys->open(sys->sprint("/n/llm/%s/chat/system", llmconn), Sys->OWRITE|Sys->OTRUNC);
	if(fd == nil) {
		sys->print("Error opening chat/system: %r\n");
		return;
	}
	
	sys->print("Reading tools.md...\n");
	tfd := sys->open("/n/llm/tools.md", Sys->OREAD);
	if(tfd == nil) tfd = sys->open("./tools.md", Sys->OREAD); # Fallback locally
	
	tools_doc := "You are a helpful AI assistant connected to an Inferno OS environment. " +
		"You have access to the following tools to accomplish the user's goals. " +
		"To invoke a tool, you MUST output a raw JSON block wrapped in exactly ```json and ```.\n" +
		"Example:\n```json\n{\n  \"name\": \"bash\",\n  \"arguments\": {\n    \"command\": \"ls -la\"\n  }\n}\n```\n\n" +
		"Available tools:\n\n";
		
	if(tfd != nil) {
		buf := array[8192] of byte;
		n := sys->read(tfd, buf, len buf);
		if(n > 0) tools_doc += string buf[0:n];
	} else {
		tools_doc += "read, write, edit, bash";
	}
	
	sys->fprint(fd, "%s", tools_doc);
}

agent_loop(ctxt: ref Draw->Context)
{
	stdin := bufio->fopen(sys->fildes(0), Sys->OREAD);
	
	for(;;) {
		sys->print("\n> ");
		input := stdin.gets('\n');
		if(input == nil) break;
		if(len input > 0 && input[len input - 1] == '\n') input = input[0:len input - 1];
		if(input == "exit" || input == "quit") break;
		
		ufd := sys->open(sys->sprint("/n/llm/%s/chat/user", llmconn), Sys->OWRITE|Sys->OTRUNC);
		if(ufd == nil) {
			sys->print("Error: Could not open user input file: %r\n");
			continue;
		}
		
		sys->fprint(ufd, "%s", input);
		ufd = nil;
		
		while(pump_assistant(ctxt)) {
			# Keep pumping the assistant if a tool was executed
		}
	}
}

pump_assistant(ctxt: ref Draw->Context): int
{
	afd := bufio->fopen(sys->open(sys->sprint("/n/llm/%s/chat/assistant", llmconn), Sys->OREAD), Sys->OREAD);
	if(afd == nil) {
		sys->print("Error: Could not open assistant output file: %r\n");
		return 0;
	}
	
	capture_mode := 0;
	json_buf := "";
	
	for(;;) {
		buf := array[1] of byte;
		n := afd.read(buf, 1);
		if(n <= 0) break;
		
		charstr := string buf[0:1];
		
		if(capture_mode) {
			json_buf += charstr;
			
			# Check for ending ``` (or </tool_call> as a fallback)
			if(len json_buf >= 3 && json_buf[len json_buf - 3:] == "```") {
				capture_mode = 0;
				json_body := json_buf[0: len json_buf - 3];
				afd = nil;
				execute_tool(ctxt, json_body);
				return 1;
			} else if(len json_buf >= 12 && json_buf[len json_buf - 12:] == "</tool_call>") {
				capture_mode = 0;
				json_body := json_buf[0: len json_buf - 12];
				afd = nil;
				execute_tool(ctxt, json_body);
				return 1;
			}
		} else {
			json_buf += charstr;
			if(len json_buf > 15) json_buf = json_buf[1:];
			
			if(len json_buf >= 7 && json_buf[len json_buf - 7:] == "```json") {
				capture_mode = 1;
				json_buf = "";
			} else if(len json_buf >= 11 && json_buf[len json_buf - 11:] == "<tool_call>") {
				capture_mode = 1;
				json_buf = "";
			} else if(len json_buf >= 12 && json_buf[len json_buf - 12:] == "```tool_call") {
				capture_mode = 1;
				json_buf = "";
			}
			
			if(!capture_mode) {
				sys->print("%s", charstr);
			}
		}
	}
	return 0;
}

execute_tool(ctxt: ref Draw->Context, tool_json: string)
{
	sys->print("\n[Executing tool call]\n");
	b := bufio->aopen(array of byte tool_json);
	if (b == nil) {
		report_tool_error("Failed to open JSON buffer");
		return;
	}
	
	(jv, err) := json->readjson(b);
	if (jv == nil) {
		report_tool_error(sys->sprint("JSON parsing failed: %s", err));
		return;
	}
	
	name_val := jv.get("name");
	if (name_val == nil || !name_val.isstring()) {
		report_tool_error("Tool call missing valid 'name' field");
		return;
	}
	name := "";
	pick v := name_val { String => name = v.s; }
	
	args_val := jv.get("arguments");
	if (args_val == nil || !args_val.isobject()) {
		report_tool_error("Tool call missing 'arguments' object");
		return;
	}
	
	result := "";
	
	case name {
	"read" =>
		path := get_string_arg(args_val, "path");
		if (path == nil) result = "Error: missing 'path' argument";
		else result = tool_read(path);
	"write" =>
		path := get_string_arg(args_val, "path");
		content := get_string_arg(args_val, "content");
		if (path == nil || content == nil) result = "Error: missing 'path' or 'content' argument";
		else result = tool_write(path, content);
	"edit" =>
		path := get_string_arg(args_val, "path");
		oldText := get_string_arg(args_val, "oldText");
		newText := get_string_arg(args_val, "newText");
		if (path == nil || oldText == nil || newText == nil) result = "Error: missing 'path', 'oldText', or 'newText' argument";
		else result = tool_edit(path, oldText, newText);
	"bash" =>
		cmd := get_string_arg(args_val, "command");
		if (cmd == nil) result = "Error: missing 'command' argument";
		else result = tool_bash(ctxt, cmd);
	* =>
		result = sys->sprint("Error: Unknown tool '%s'", name);
	}
	
	sys->print("Result:\n%s\n", result);
	
	# Send result back to model
	ufd := sys->open(sys->sprint("/n/llm/%s/chat/user", llmconn), Sys->OWRITE);
	if(ufd != nil) {
		sys->seek(ufd, big 0, Sys->SEEKEND);
		sys->fprint(ufd, "\n<tool_result>\n%s\n</tool_result>\n", result);
	}
}

get_string_arg(args: ref JValue, name: string): string
{
	v := args.get(name);
	if(v != nil && v.isstring()) {
		pick sval := v { String => return sval.s; }
	}
	return nil;
}

report_tool_error(err: string)
{
	sys->print("%s\n", err);
	ufd := sys->open(sys->sprint("/n/llm/%s/chat/user", llmconn), Sys->OWRITE);
	if(ufd != nil) {
		sys->seek(ufd, big 0, Sys->SEEKEND);
		sys->fprint(ufd, "\n<tool_result>\n%s\n</tool_result>\n", err);
	}
}

tool_read(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) return sys->sprint("Error: Could not open file %s: %r", path);
	
	# Naive read up to a certain limit
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0) return sys->sprint("Error reading file: %r");
	
	if(n == 0) return "File is empty.";
	return string buf[0:n];
}

tool_write(path: string, content: string): string
{
	fd := sys->open(path, Sys->OWRITE|Sys->OTRUNC);
	if(fd == nil) fd = sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil) return sys->sprint("Error: Could not open or create file %s: %r", path);
	
	buf := array of byte content;
	n := sys->write(fd, buf, len buf);
	if(n < 0) return sys->sprint("Error writing to file: %r");
	
	return "File written successfully.";
}

tool_edit(path: string, oldText: string, newText: string): string
{
	content := tool_read(path);
	if(len content > 5 && content[0:5] == "Error") return content;
	
	(n, pieces) := sys->tokenize(content, oldText); # Actually Limbo tokenize splits by *any* char in delim. We need str->splitstr. Let's use string module.
	
	(a, b) := str->splitstrl(content, oldText);
	if(b == nil || len b == 0) return "Error: oldText not found in file.";
	
	new_content := a + newText + b[len oldText:];
	
	return tool_write(path, new_content);
}

tool_bash(ctxt: ref Draw->Context, cmd: string): string
{
	sys->print("Running shell command: %s\n", cmd);
	
	tmp := "/tmp/sh_out_" + string sys->millisec();
	
	# Evaluate inside the native inferno shell, redirecting stdout and stderr to the tmp file
	res := sh->system(ctxt, "{ " + cmd + " } > " + tmp + " >[2=1]");
	
	output := tool_read(tmp);
	sys->remove(tmp);
	
	if(len output > 14 && output[0:14] == "Error: Could n") output = "";
	
	if(res != nil) {
		return "Exit Status: " + res + "\n" + output;
	}
	
	if(len output == 0) return "Command executed with no output.";
	return output;
}
