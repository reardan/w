import tests.safe_generic_buffer_import_fixture as helper

int main():
	return helper.vector_identity[int](7) + helper.vector_identity(8) - 15
