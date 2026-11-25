/*
The running program's own executable path, for programs that locate
siblings (helper binaries, assets) or re-execute themselves.

  self_exe_path()   absolute path (owned), or 0 when unavailable

Linux and Android read the /proc/self/exe link; Darwin asks the kernel
through proc_info(PROC_PIDPATHINFO), the call behind libproc's
proc_pidpath, since it has no /proc. Other targets have no
implementation yet, so importing this module there fails to compile.
*/
import lib.lib
import lib.__arch__.self_exe
