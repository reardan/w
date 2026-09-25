# bin/wexec's entry point. The executor itself lives in tools/wexec.w,
# kept free of a main() so tools/wbuildd.w can import it and run builds
# in-process (docs/projects/wbuildd.md, "Build RPC").
import tools.wexec


int main(int argc, int argv):
	return wexec_main(argc, argv)
