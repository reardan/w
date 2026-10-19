# wbuild: binary=ios_plist tag=tests
# Small XML plist writer for the native UIKit development bundle.
import tools.host_tools
import libs.standard.formats.xml.etree

xml_element* ip_value(xml_element* dict, char* key, char* tag, char* value = 0):
	xml_set_text(xml_subelement(dict, c"key"), key)
	xml_element* item = xml_subelement(dict, tag)
	if (value != 0): xml_set_text(item, value)
	return item

void ip_write(char* app, char* platform, char* identifier, int framework):
	xml_element* root = xml_element_new(c"plist")
	xml_set(root, c"version", c"1.0")
	xml_element* dict = xml_subelement(root, c"dict")
	ip_value(dict, c"CFBundleDevelopmentRegion", c"string", c"en")
	ip_value(dict, c"CFBundleInfoDictionaryVersion", c"string", c"6.0")
	ip_value(dict, c"CFBundleShortVersionString", c"string", c"1.0")
	ip_value(dict, c"CFBundleVersion", c"string", c"1")
	ip_value(dict, c"MinimumOSVersion", c"string", c"17.0")
	xml_set_text(xml_subelement(ip_value(dict, c"CFBundleSupportedPlatforms", c"array"), c"string"), platform)
	char* executable = c"WApp"
	char* name = c"W on iPhone"
	char* kind = c"APPL"
	char* path = path_join(app, c"Info.plist")
	if (framework):
		identifier = c"org.wlang.WIOS"
		executable = c"WIOS"
		name = c"WIOS"
		kind = c"FMWK"
		path = path_join(app, c"Frameworks/WIOS.framework/Info.plist")
	else:
		xml_element* devices = ip_value(dict, c"UIDeviceFamily", c"array")
		xml_set_text(xml_subelement(devices, c"integer"), c"1")
		xml_set_text(xml_subelement(devices, c"integer"), c"2")
		ip_value(dict, c"UILaunchScreen", c"dict")
		xml_element* orientations = ip_value(dict, c"UISupportedInterfaceOrientations", c"array")
		for char* value in ht_command(c"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"): xml_set_text(xml_subelement(orientations, c"string"), value)
	ip_value(dict, c"CFBundleIdentifier", c"string", identifier)
	ip_value(dict, c"CFBundleExecutable", c"string", executable)
	ip_value(dict, c"CFBundleName", c"string", name)
	ip_value(dict, c"CFBundlePackageType", c"string", kind)
	char* text = strjoin(c"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n", xml_tostring(root))
	ht_write(path, text, strlen(text))

int main(int argc, int argv):
	ht_require(argc == 4, c"usage: ios_plist APP PLATFORM IDENTIFIER")
	args_init(argc, argv)
	ip_write(args_get(1), args_get(2), args_get(3), 0)
	ip_write(args_get(1), args_get(2), args_get(3), 1)
	return 0
