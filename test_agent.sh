#!/dis/sh.dis
load std
echo 'mounting...'
mkdir -p /n/llm
mount -A tcp!127.0.0.1!6701 /n/llm
echo 'running agent...'
/agent.dis
