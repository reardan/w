#!/bin/sh
# Cursor postToolUse hook wrapper: bootstrap the W-native check hook
# (tools/hooks/w_check_hook.w -> bin/whook) and pipe the payload through.
# whook runs './bin/wv2 check --json' on the edited .w file and prints
# {"additional_context": "<diagnostics>"} for the agent, or {} for
# anything that is not a W source edit. Fail-open: any bootstrap problem
# reports nothing rather than blocking the agent.
set -u
cd "${CURSOR_PROJECT_DIR:-.}" 2>/dev/null || { printf '{}\n'; exit 0; }
payload=$(cat)

# Cheap pre-filter: payloads without a .w path never need the toolchain.
case "$payload" in
	*'.w'*) ;;
	*) printf '{}\n'; exit 0 ;;
esac

mkdir -p bin
if [ ! -x bin/wv2 ]; then
	./w w.w -o bin/wv2 >/dev/null 2>&1 || { printf '{}\n'; exit 0; }
fi
if [ ! bin/whook -nt tools/hooks/w_check_hook.w ]; then
	./bin/wv2 tools/hooks/w_check_hook.w -o bin/whook >/dev/null 2>&1 || { printf '{}\n'; exit 0; }
fi
printf '%s' "$payload" | ./bin/whook
