# expect_fail
# expect_stderr: protobuf message 'pbe_later' is declared but never defined
# A forward declaration ('message Name') must be completed before use.
import libs.extras.protobuf.message


message pbe_later


message pbe_holder:
	pbe_later l = 1


int main():
	pbe_holder* h = from_proto(pbe_holder, c"", 0)
	return 0
