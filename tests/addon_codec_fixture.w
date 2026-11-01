# Imported by the addon engine test: message declarations go through the
# module parser, and their descriptors are first emitted by addon code.
import libs.extras.protobuf.message


message addon_codec_leaf:
	int32 value = 1


message addon_codec_record:
	addon_codec_leaf child = 1
	string label = 2
