
/*
struct ethernet_header:
	char dest[6]
	char sender[6]
	uint16 protocol # 0x806


struct arp_packet:
	uint16 hardware_type # 1 = ETHERNET
	uint16 protocol_type # 0x800 = IP
	char hw_len # 6
	char protocol_length # 4
	uint16 operation # 2
	char sha[6] # sender mac
	char spa[4] # sender ip
	char tha[6] # target mac
	char tpa[4] # target ip


struct ethernet_arp_packet:
	ethernet_header eth
	arp_packet arp


struct sock_addr_link_layer:
	protocol # ETH_P_ARP
	if_index # interf.Index
	ha_type # ARPHRD_ETHER
*/

/*
struct addrinfo:
	int ai_flags
	int ai_family
	int ai_socktype
	int ai_protocol
	int addrlen
	sockaddr* addr
	char* canon_name
	addrinfo* next

struct sockaddr_in:
	int16 family
	uint16 port
	int ip_address
	int zero1
	int zero2

struct sockaddr:
	uint16 family
	sockaddr_in data
*/
import lib

# https://css.bz/2016/12/08/go-raw-sockets.html
# https://www.opensourceforu.com/2015/03/a-guide-to-using-raw-sockets/

# https://elixir.bootlin.com/linux/v5.0.21/source/include/linux/socket.h#L379
# http://linasm.sourceforge.net/docs/syscalls/network.php
# https://linux.die.net/man/3/getaddrinfo
int socket(int family, int socket_type, int protocol):
	return syscall(41, family, socket_type, protocol)


int send_to(int file, char* buf, int size, int flags, char* dest, int len):
	return syscall7(44, file, buf, size, flags, dest, len)



# https://github.com/openbsd/src/blob/master/sys/sys/socket.h
int main(int argc, int argv):
	# Address Families
	int af_unspec = 0
	int af_unix = 1
	int af_local = 1
	int af_inet = 2
	# ...

	# Socket Type
	int sock_stream = 1
	int sock_dgram = 2
	int sock_raw = 3
	int sockrdm = 4
	int sock_seq = 5

	# https://github.com/spotify/linux/blob/master/include/linux/if_ether.h
	# ETH types
	int eth_p_all = 3
	# IPPROTO_RAW

	int udp = 1
	if (udp):
		int file = socket(af_inet, sock_dgram, 0)
		
		close(file)


	int raw = 0
	if (raw):
		# TODO: Create Raw Socket
		int file = socket(af_inet, sock_raw, 0)

		# Send To
		int packet = 0
		int len = 0
		int addr = 0
		send_to(file, packet, len, addr)

	return 0
