# KVM execution currently requires a Linux x64 host.
import lib.lib


int kvm_open_system():
	return open(c"/dev/kvm", 2 | 524288, 0)
