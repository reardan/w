# SDK/NDK packaging helpers; usable without a connected device.
import tools.host_tools
import lib.str
import libs.standard.cli.argparse
import libs.standard.text.re
import libs.standard.formats.xml.etree
import libs.standard.fs.glob
import libs.standard.archive.zip

char* ab_env(char* name, char* fallback):
	char* value = env_get(name)
	if (value == 0 || value[0] == 0): return fallback
	return value

int ab_match(char* pattern, char* value):
	return re_fullmatch(re_compile(pattern, 0), value) != 0

list[int] ab_version(char* path):
	list[int] result = new list[int]
	char* name = path_basename(path)
	int i = 0
	while (name[i] != 0):
		if (name[i] < '0' || name[i] > '9'):
			i = i + 1
			continue
		int n = 0
		while (name[i] >= '0' && name[i] <= '9'):
			ht_require(n < 100000000, c"SDK version component too large")
			n = n * 10 + name[i] - '0'
			i = i + 1
		result.push(n)
	return result

int ab_newer(char* a, char* b):
	if (b == 0): return 1
	list[int] av = ab_version(a)
	list[int] bv = ab_version(b)
	for i in range(av.length):
		if (i >= bv.length): return 1
		if (av[i] != bv[i]): return av[i] > bv[i]
	return 0

char* ab_newest(char* directory, char* pattern):
	char* best = 0
	for char* path in glob_glob(path_join(directory, pattern)):
		char* name = path_basename(path)
		if (shutil_is_dir(path) && !contains(name, c"rc") && !contains(name, c"beta") && ab_newer(path, best)): best = path
	ht_require(best != 0, strjoin(c"No installed SDK package in ", directory))
	return best

void ab_attr(xml_element* element, char* key, char* value):
	xml_set(element, strjoin(c"{http://schemas.android.com/apk/res/android}", key), value)

void ab_resource(char* resources, char* name, char* content):
	char* path = path_join(resources, name)
	ht_mkdir(path_dirname(path))
	ht_write(path, content, strlen(content))

void ab_manifest(arg_namespace* args, char* path, char* resources):
	xml_element* root = xml_fromstring(ht_read(c"tools/android/AndroidManifest.xml").data)
	ht_require(root != 0, c"invalid base Android manifest")
	xml_set(root, c"package", argparse_get(args, c"package"))
	ab_attr(xml_find(root, c"uses-sdk"), c"minSdkVersion", argparse_get(args, c"min_sdk"))
	xml_element* app = xml_find(root, c"application")
	ab_attr(app, c"label", argparse_get(args, c"label"))
	char* theme = c"@android:style/Theme.Material.Light.NoActionBar"
	if (strcmp(argparse_get(args, c"theme"), c"daynight") == 0):
		theme = c"@style/WDayNight"
		ab_resource(resources, c"values/w_theme.xml", c"<?xml version=\"1.0\" encoding=\"utf-8\"?><resources><style name=\"WDayNight\" parent=\"@android:style/Theme.DeviceDefault.DayNight\"><item name=\"android:windowActionBar\">false</item><item name=\"android:windowNoTitle\">true</item></style></resources>\n")
	ab_attr(app, c"theme", theme)
	xml_element* activity = xml_find(app, c"activity")
	ab_attr(activity, c"name", c"org.wlang.androiddemo.WActivity")
	char* icon = argparse_get(args, c"icon")
	if (icon != 0):
		char* java = 0
		char* home = env_get(c"JAVA_HOME")
		if (home != 0 && path_exists(path_join(home, c"bin/java"))): java = path_join(home, c"bin/java")
		if (java == 0): java = c"java"
		list[char*] command = ht_argv(java, c"-Djava.awt.headless=true", c"tools/android/icon/WIcon.java", ht_resolve(path_expand_user(icon)), resources)
		char* background = argparse_get(args, c"icon_background")
		if (background != 0): command.push(background)
		ht_checked(command)
		ab_attr(app, c"icon", c"@mipmap/w_app_icon")
		ab_attr(app, c"roundIcon", c"@mipmap/w_app_icon")
	list[char*] permissions = new list[char*]
	if (argparse_get_bool(args, c"notifications")):
		permissions = ht_command(c"POST_NOTIFICATIONS FOREGROUND_SERVICE FOREGROUND_SERVICE_DATA_SYNC")
		xml_element* service = xml_subelement(app, c"service")
		ab_attr(service, c"name", c"org.wlang.androiddemo.WService")
		ab_attr(service, c"exported", c"false")
		ab_attr(service, c"foregroundServiceType", c"dataSync")
	if (argparse_get_bool(args, c"internet")):
		permissions.push(c"INTERNET")
		ab_attr(app, c"networkSecurityConfig", c"@xml/w_network_security")
		ab_resource(resources, c"xml/w_network_security.xml", c"<?xml version=\"1.0\" encoding=\"utf-8\"?><network-security-config><base-config cleartextTrafficPermitted=\"false\"/><domain-config cleartextTrafficPermitted=\"true\"><domain includeSubdomains=\"false\">127.0.0.1</domain><domain includeSubdomains=\"false\">localhost</domain></domain-config></network-security-config>\n")
	for char* permission in permissions:
		xml_element* item = xml_element_new(c"uses-permission")
		ab_attr(item, c"name", strjoin(c"android.permission.", permission))
		root.children.insert(1, item)
	for char* scheme in argparse_get_list(args, c"scheme"):
		ab_attr(activity, c"launchMode", c"singleTask")
		xml_element* intents = xml_subelement(activity, c"intent-filter")
		ab_attr(xml_subelement(intents, c"action"), c"name", c"android.intent.action.VIEW")
		for char* category in ht_command(c"DEFAULT BROWSABLE"): ab_attr(xml_subelement(intents, c"category"), c"name", strjoin(c"android.intent.category.", category))
		ab_attr(xml_subelement(intents, c"data"), c"scheme", scheme)
	char* text = xml_tostring(root)
	ht_write(path, text, strlen(text))

arg_parser* ab_parser():
	arg_parser* parser = argparse_new(c"android_build")
	arg_spec* source = argparse_add_positional_nargs(parser, c"source", ARGPARSE_OPTIONAL, c"W application")
	argparse_arg_default(source, c"graphics/android/demo.w")
	argparse_arg_default(argparse_add_option(parser, c"--package", c"ID", c"application id"), c"org.wlang.androiddemo")
	argparse_arg_default(argparse_add_option(parser, c"--label", c"TEXT", c"launcher label"), c"W on Android")
	argparse_add_option(parser, c"--icon", c"PNG", c"launcher icon")
	argparse_add_option(parser, c"--icon-background", c"COLOR", c"adaptive icon background")
	arg_spec* theme = argparse_add_option(parser, c"--theme", c"THEME", c"native theme")
	argparse_arg_default(theme, c"light")
	argparse_arg_choices(theme, c"daynight,light")
	argparse_arg_default(argparse_add_int(parser, c"--min-sdk", c"N", c"minimum Android API"), c"28")
	argparse_add_list(parser, c"--scheme", c"SCHEME", c"deep-link scheme (repeatable)")
	argparse_add_flag(parser, c"--internet", c"Internet permission and loopback HTTP")
	argparse_add_flag(parser, c"--notifications", c"notifications and foreground service")
	argparse_add_flag(parser, c"--probes", c"device compiler/ABI probes")
	argparse_add_option(parser, c"--import-root", c"PATH", c"extra import root")
	argparse_arg_default(argparse_add_option(parser, c"--keystore", c"FILE", c"development key"), ab_env(c"W_ANDROID_KEYSTORE", c"bin/android/debug.keystore"))
	argparse_arg_default(argparse_add_option(parser, c"--keystore-pass", c"PASS", c"key password"), ab_env(c"W_ANDROID_KEYSTORE_PASS", c"android"))
	argparse_arg_default(argparse_add_option(parser, c"--key-alias", c"ALIAS", c"key alias"), ab_env(c"W_ANDROID_KEY_ALIAS", c"androiddebugkey"))
	argparse_arg_default(argparse_add_option(parser, c"--apk-name", c"NAME", c"APK basename"), c"WApp.apk")
	argparse_arg_default(argparse_add_option(parser, c"--compiler", c"PATH", c"W compiler"), ab_env(c"W_COMPILER", c"bin/wv2"))
	argparse_arg_default(argparse_add_option(parser, c"--sdk", c"PATH", c"Android SDK"), ab_env(c"ANDROID_HOME", ab_env(c"ANDROID_SDK_ROOT", c"~/Android/Sdk")))
	arg_spec* ndk = argparse_add_option(parser, c"--ndk", c"PATH", c"Android NDK")
	if (env_get(c"ANDROID_NDK_HOME") != 0): argparse_arg_default(ndk, env_get(c"ANDROID_NDK_HOME"))
	argparse_arg_default(argparse_add_option(parser, c"--out", c"PATH", c"output directory"), c"bin/android/app")
	return parser

void ab_zip_add(zip_writer* writer, char* file, char* name, int method):
	string_builder* data = ht_read(file)
	ht_require(zip_writer_add(writer, name, data.data, data.length, method) == 0, strjoin(c"cannot package ", name))
	string_free(data)
