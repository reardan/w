# Generated from tests/protobuf/sample.proto by tools/proto_to_w.w. Do not edit.
# proto package: example.shop
# note: services are not generated (RPC is out of scope)
import libs.extras.protobuf.message


enum Order_Status:
	Order_STATUS_UNKNOWN = 0
	Order_STATUS_OPEN = 1
	Order_STATUS_SHIPPED = 2


enum Country:
	COUNTRY_UNSPECIFIED = 0
	COUNTRY_NO = 47
	COUNTRY_US = 1


message Address:
	string city = 1
	fixed32 zip = 2
	Country country = 3


message Customer:
	string name = 1
	bytes avatar = 2
	Address address = 3
	repeated string emails = 4


message LineItem:
	string sku = 1
	uint32 quantity = 2
	bool gift = 3
	repeated sint32 adjustments = 4


# map entry (key = 1, value = 2)
message Order_TagsEntry:
	string key = 1
	int32 value = 2


message Order_Voucher:
	string code = 1
	sint32 discount = 2


message Order:
	uint32 id = 1
	Customer customer = 2
	repeated LineItem items = 3
	Order_Status status = 4
	repeated Order_TagsEntry tags = 5
	string card_token = 6  # oneof payment
	Order_Voucher voucher = 7  # oneof payment
	string note = 8  # optional (presence not tracked)
