class_name ROMVerifier
extends Node

const VALID_HASHES := [
	"6a54024d5abe423b53338c9b418e0c2ffd86fed529556348e52ffca6f9b53b1a",
	"c9b34443c0414f3b91ef496d8cfee9fdd72405d673985afa11fb56732c96152b"
]

const ROM_URL : String = "https://dl.dropboxusercontent.com/scl/fi/74c58s8cl2gje4ygqq1xa/main.nes?rlkey=mruma3m6a1mi0dkp5covtge5t&dl=1"

var args: PackedStringArray
var rom_arg: String = ""

func _ready() -> void:
	args = OS.get_cmdline_args()
	Global.get_node("GameHUD").hide()

	# Try command line ROMs first
	for i in range(args.size()):
		match args[i]:
			"-rom":
				if i + 1 < args.size():
					rom_arg = args[i + 1].replace("\\", "/")
					print("ROM argument found: ", rom_arg)

	if rom_arg != "":
		if rom_arg.begins_with("http://") or rom_arg.begins_with("https://"):
			if await _download_then_handle(rom_arg):
				return
		else:
			if handle_rom(rom_arg):
				return

	# Fallback: local ROM in exe dir
	var local_rom := find_local_rom()
	if local_rom != "" and handle_rom(local_rom):
		return

	# Fallback: attempt ROM download
	if ROM_URL != "" and (ROM_URL.begins_with("http://") or ROM_URL.begins_with("https://")):
		print("ROM URL:", ROM_URL)
		if await _download_then_handle(ROM_URL):
			return

	# Otherwise wait for dropped files
	get_window().files_dropped.connect(on_file_dropped)
	await get_tree().physics_frame

	# Window setup
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)


# Downloads `url` into a temporary file and tries to handle it.
# Returns true on success (validated & processed), false otherwise.
func _download_then_handle(url: String) -> bool:
	print("Downloading:", url)
	var http := HTTPRequest.new()
	add_child(http)

	var req_err := http.request(url)
	if req_err != OK:
		print("HTTPRequest.request() failed:", req_err)
		http.queue_free()
		return false

	var result_arr = await http.request_completed
	http.queue_free()

	if result_arr.size() < 4:
		print("Unexpected HTTPRequest.request_completed args")
		return false

	var result: int = int(result_arr[0])
	var response_code: int = int(result_arr[1])
	var body: PackedByteArray = result_arr[3] as PackedByteArray

	if result != OK:
		print("HTTP request failed (result):", result)
		return false
	if response_code < 200 or response_code >= 300:
		print("HTTP response code:", response_code)
		return false

	# write body to temp file (use user data dir)
	var tmp_path := OS.get_user_data_dir() + "/" + "downloaded_rom.tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if not f:
		print("Failed to open temp file for writing:", tmp_path)
		return false
	f.store_buffer(body)
	f.close()

	# validate + handle temp file
	var ok := handle_rom(tmp_path)

	# remove temp on failure; if success we leave it so copy_rom can use it (or you can delete)
	if not ok:
		var da := DirAccess.open(OS.get_user_data_dir())
		if da:
			da.remove("downloaded_rom.tmp")
	return ok


func find_local_rom() -> String:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var dir := DirAccess.open(exe_dir)
	if not dir:
		return ""
	for file_name in dir.get_files():
		if file_name.to_lower().ends_with(".nes"):
			return exe_dir.path_join(file_name)
	return ""


func on_file_dropped(files: PackedStringArray) -> void:
	for file in files:
		if file.to_lower().ends_with(".zip"):
			zip_error()
			return
		if handle_rom(file):
			return
	error()


func handle_rom(path: String) -> bool:
	print("handle_rom: checking", path)
	if not is_valid_rom(path):
		print("handle_rom: is_valid_rom returned false for ", path)
		return false
	Global.rom_path = path
	copy_rom(path)
	verified()
	return true


func copy_rom(src_path: String) -> void:
	# robust copy that works on exports: read then write
	var fsrc := FileAccess.open(src_path, FileAccess.READ)
	if not fsrc:
		push_error("copy_rom: could not open src: " + src_path)
		return
	var buf := fsrc.get_buffer(fsrc.get_length())
	fsrc.close()

	var fdst := FileAccess.open(Global.rom_path, FileAccess.WRITE)
	if not fdst:
		push_error("copy_rom: could not open dst: " + Global.rom_path)
		return
	fdst.store_buffer(buf)
	fdst.close()

	# optional: delete tmp if it is in user:// and the src_path equals it
	if src_path.begins_with(OS.get_user_data_dir()):
		var filename := src_path.get_file()
		if filename == "downloaded_rom.tmp":
			var da := DirAccess.open(OS.get_user_data_dir())
			if da:
				da.remove(filename)


# --- IMPORTANT: EXACTLY MATCH your original hash algorithm ---
# original: read bytes, slice(16), Marshalls.raw_to_base64(data).sha256_text()
static func get_hash(file_path: String) -> String:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if not f:
		return ""
	var size := int(f.get_length())
	if size <= 16:
		f.close()
		return ""
	var total := f.get_buffer(size)
	f.close()

	var data_slice := total.slice(16) # slice off first 16 bytes (same as original)

	# Convert the sliced bytes to base64 string exactly like Marshalls.raw_to_base64()
	var base64_str := Marshalls.raw_to_base64(data_slice)
	# Compute SHA256 of that base64 string using String.sha256_text() (this returns hex lowercase)
	var hash_hex := base64_str.sha256_text()
	# Debug: print the computed hash so you can compare
	print("Computed hash for ", file_path, ": ", hash_hex)
	return hash_hex


static func is_valid_rom(rom_path := "") -> bool:
	var h := get_hash(rom_path)
	if h == "":
		return false
	# Debug: show valid list and computed value if mismatch
	if not (h in VALID_HASHES):
		print("Hash mismatch. Computed:", h, "Expected any of:", VALID_HASHES)
		return false
	return true


func error() -> void:
	%Error.show()
	$ErrorSFX.play()


func zip_error() -> void:
	%ZipError.show()
	$ZipError.play()


func verified() -> void:
	$BGM.queue_free()
	%DefaultText.queue_free()
	%SuccessMSG.show()
	$SuccessSFX.play()
	await get_tree().create_timer(3, false).timeout
	
	var target_scene := "res://Scenes/Levels/TitleScreen.tscn"
	if not Global.rom_assets_exist:
		target_scene = "res://Scenes/Levels/RomResourceGenerator.tscn"
	Global.transition_to_scene(target_scene)


func _exit_tree() -> void:
	Global.get_node("GameHUD").show()


func create_file_pointer(file_path: String) -> void:
	var pointer := FileAccess.open(Global.ROM_POINTER_PATH, FileAccess.WRITE)
	if pointer:
		pointer.store_string(file_path)
		pointer.close()
