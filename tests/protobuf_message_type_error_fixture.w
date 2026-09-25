# expect_fail
# expect_stderr: unsupported protobuf field type 'pbe_plain'
# Only protobuf scalar spellings, enums and other messages are fields.
import libs.extras.protobuf.message


struct pbe_plain:
	int x


message pbe_holder:
	pbe_plain p = 1


int main():
	return 0
