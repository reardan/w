# Shared-library TLS needs a dynamic TLS ABI and is rejected explicitly.
thread_local int shared_tls

export int shared_tls_value():
	return shared_tls
