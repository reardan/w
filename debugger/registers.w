/*
Register access seam (#123 phase 2 remainder: docs/projects/debugger_attach.md).

Frame walking and locals addressing only ever need two logical values from
the trapped register file: the current pc and the current sp. Everything
else about *how* those are stored -- the in-process signal frame's
sigcontext (debugger/sigcontext.w) versus attach mode's ptrace
user_regs_struct (debugger/attach.w) -- is exactly the kind of detail a
seam should hide from a shared caller, the same way debugger/memory.w
already hides "direct load" versus "PTRACE_PEEKDATA" behind
dbg_mem_readable/dbg_mem_read.

dbg_reg_pc_fn/dbg_reg_sp_fn are the two function-pointer slots (the same
convention memory.w and disas.w use: an int holding a code address, cast
back to a callable pointer at the call site). dbg_registers_init()
installs the in-process default, so every existing in-process caller needs
no seam awareness at all; debugger/attach.w installs its own ptrace-backed
pair instead once an attach session starts.

The in-process backend reads dbg_reg_context, a plain global mirroring the
sigcontext pointer wdbg.w already threads explicitly through its own call
chain (wdbg_trap/wdbg_fatal take it as a parameter, as documented in
debugger_attach.md's "still deferred" note). wdbg.w sets dbg_reg_context to
that same pointer once per stop, so this is a strictly additive read path:
none of wdbg.w's existing ctx_*(context) call sites change, and nothing
about their behavior does either.
*/
import lib.lib
import debugger.sigcontext


int dbg_reg_pc_fn /* int f() -> current pc (absolute address) */
int dbg_reg_sp_fn /* int f() -> current sp (absolute address) */


# --- in-process (sigcontext) implementation, the default -----------------

# Set by wdbg.w once per stop (wdbg_trap/wdbg_fatal), before any seam
# consumer runs. 0 outside of a trapped stop.
int dbg_reg_context


int dbg_reg_pc_local():
	return ctx_eip(dbg_reg_context)


int dbg_reg_sp_local():
	return ctx_esp(dbg_reg_context)


void dbg_registers_use_local():
	dbg_reg_pc_fn = cast(int, dbg_reg_pc_local)
	dbg_reg_sp_fn = cast(int, dbg_reg_sp_local)


void dbg_registers_init():
	dbg_registers_use_local()


# --- the seam: every caller (in-process or attach) goes through these ----

int dbg_reg_pc():
	int* fn = cast(int*, dbg_reg_pc_fn)
	return fn()


int dbg_reg_sp():
	int* fn = cast(int*, dbg_reg_sp_fn)
	return fn()
