extends Node3D

# Persistent settings
const SETTINGS_FILE = "user://settings.cfg"
const MAX_RECORDING_TIME: float = 20.0

var server_url: String = "192.168.15.71:8080"
var persona: String = "You are a helpful and polite AI assistant."
var selected_mic: String = ""

# In-memory session summary (not saved persistently)
var pseudo_memory: String = ""

# State variables
var is_recording: bool = false
var recording_timer: float = 0.0
var record_effect: AudioEffectRecord = null
var record_bus_index: int = -1
var is_vr_mode: bool = false

# UI Node references
@onready var xr_origin: XROrigin3D = $XROrigin3D
@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var hud: Control = $CanvasLayer/HUD
@onready var red_circle: Control = $CanvasLayer/HUD/RedCircle
@onready var ai_response_label: Label = $CanvasLayer/HUD/AIResponseLabel
@onready var menu_panel: PanelContainer = $CanvasLayer/HUD/MenuPanel
@onready var status_label: Label = $CanvasLayer/HUD/MenuPanel/VBox/StatusLabel
@onready var ip_line_edit: LineEdit = $CanvasLayer/HUD/MenuPanel/VBox/IPHBox/IPLineEdit
@onready var test_button: Button = $CanvasLayer/HUD/MenuPanel/VBox/IPHBox/TestConnectionButton
@onready var mic_option_button: OptionButton = $CanvasLayer/HUD/MenuPanel/VBox/MicHBox/MicOptionButton
@onready var persona_text_edit: TextEdit = $CanvasLayer/HUD/MenuPanel/VBox/PersonaTextEdit
@onready var memory_text_edit: TextEdit = $CanvasLayer/HUD/MenuPanel/VBox/MemoryTextEdit
@onready var clear_memory_button: Button = $CanvasLayer/HUD/MenuPanel/VBox/ClearMemoryButton
@onready var http_request: HTTPRequest = $HTTPRequest
@onready var audio_stream_record: AudioStreamPlayer = $AudioStreamRecord
@onready var vr_menu_3d: Node3D = $VRMenu3D

func _ready() -> void:
	# Assign AudioStreamMicrophone to record audio input
	if audio_stream_record:
		audio_stream_record.stream = AudioStreamMicrophone.new()

	# Initialize OpenXR if available
	var xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		print("OpenXR initialized successfully. Enabling VR mode.")
		get_viewport().use_xr = true
		is_vr_mode = true
	else:
		print("OpenXR not initialized. Falling back to PC mode.")

	# Setup Audio Recording Bus & Effect dynamically if missing
	setup_audio_record_bus()

	# Populate Microphones
	setup_microphone_list()

	# Load Settings
	load_settings()

	# Connect UI Signals
	test_button.pressed.connect(_on_test_connection_pressed)
	clear_memory_button.pressed.connect(_on_clear_memory_pressed)
	mic_option_button.item_selected.connect(_on_mic_selected)
	ip_line_edit.text_changed.connect(_on_ip_changed)
	persona_text_edit.text_changed.connect(_on_persona_changed)
	http_request.request_completed.connect(_on_http_request_completed)

	# Custom Red Circle Drawing
	red_circle.draw.connect(_on_red_circle_draw)

	# Configure UI focus for Keyboard / Joypad D-Pad navigation
	setup_ui_focus_chain()

	update_ui_elements()

func _process(delta: float) -> void:
	if is_recording:
		recording_timer -= delta
		red_circle.queue_redraw()
		if recording_timer <= 0.0:
			recording_timer = 0.0
			stop_ptt_recording_and_send()

func setup_audio_record_bus() -> void:
	record_bus_index = AudioServer.get_bus_index("Record")
	if record_bus_index == -1:
		AudioServer.add_bus()
		record_bus_index = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(record_bus_index, "Record")

	# Unmute record bus so AudioEffectRecord receives audio
	AudioServer.set_bus_mute(record_bus_index, false)
	# Set volume to -80.0 dB to prevent audio feedback through speakers
	AudioServer.set_bus_volume_db(record_bus_index, -80.0)

	if AudioServer.get_bus_effect_count(record_bus_index) == 0:
		var effect = AudioEffectRecord.new()
		AudioServer.add_bus_effect(record_bus_index, effect)

	record_effect = AudioServer.get_bus_effect(record_bus_index, 0) as AudioEffectRecord

func _on_red_circle_draw() -> void:
	if red_circle.visible:
		var center = red_circle.size / 2.0
		var radius = min(center.x, center.y) - 5.0
		# Draw solid red circle
		red_circle.draw_circle(center, radius, Color(0.9, 0.1, 0.1, 0.9))

		# Draw countdown number centered inside red circle
		var seconds_left = int(ceil(recording_timer))
		var font = ThemeDB.fallback_font
		var font_size = 28
		var text_str = str(seconds_left)
		var string_size = font.get_string_size(text_str, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		var text_pos = center + Vector2(-string_size.x / 2.0, string_size.y / 3.0)

		red_circle.draw_string(font, text_pos, text_str, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE)

func setup_ui_focus_chain() -> void:
	ip_line_edit.focus_mode = Control.FOCUS_ALL
	test_button.focus_mode = Control.FOCUS_ALL
	mic_option_button.focus_mode = Control.FOCUS_ALL
	persona_text_edit.focus_mode = Control.FOCUS_ALL
	clear_memory_button.focus_mode = Control.FOCUS_ALL

	ip_line_edit.focus_neighbor_right = test_button.get_path()
	test_button.focus_neighbor_left = ip_line_edit.get_path()

	ip_line_edit.focus_neighbor_bottom = mic_option_button.get_path()
	test_button.focus_neighbor_bottom = mic_option_button.get_path()
	mic_option_button.focus_neighbor_top = ip_line_edit.get_path()
	mic_option_button.focus_neighbor_bottom = persona_text_edit.get_path()
	persona_text_edit.focus_neighbor_top = mic_option_button.get_path()
	persona_text_edit.focus_neighbor_bottom = clear_memory_button.get_path()
	clear_memory_button.focus_neighbor_top = persona_text_edit.get_path()

func setup_microphone_list() -> void:
	mic_option_button.clear()
	var devices = AudioServer.get_input_device_list()
	for i in range(devices.size()):
		var dev_name = devices[i]
		mic_option_button.add_item(dev_name, i)
		if dev_name == AudioServer.get_input_device():
			mic_option_button.select(i)

func _unhandled_input(event: InputEvent) -> void:
	# Toggle Menu
	if event.is_action_pressed("toggle_menu"):
		menu_panel.visible = !menu_panel.visible
		if menu_panel.visible:
			ip_line_edit.grab_focus()
			position_vr_menu_if_needed()

	# Push To Talk handling
	if event.is_action_pressed("ptt"):
		start_ptt_recording()
	elif event.is_action_released("ptt"):
		stop_ptt_recording_and_send()

func _input(event: InputEvent) -> void:
	# Check spacebar / PTT event if not handled or when UI controls have focus
	if event.is_action_pressed("ptt") and not is_recording:
		if event is InputEventKey and event.keycode == KEY_SPACE:
			var focused = get_viewport().gui_get_focus_owner()
			if focused is LineEdit or focused is TextEdit:
				return # Don't record when typing text into LineEdit/TextEdit
			start_ptt_recording()
	elif event.is_action_released("ptt") and is_recording:
		stop_ptt_recording_and_send()

func position_vr_menu_if_needed() -> void:
	if is_vr_mode and xr_camera:
		var cam_transform = xr_camera.global_transform
		vr_menu_3d.global_transform.origin = cam_transform.origin + cam_transform.basis.z * -1.5
		vr_menu_3d.look_at(cam_transform.origin, Vector3.UP)
		vr_menu_3d.rotate_y(PI)

func start_ptt_recording() -> void:
	if is_recording or not record_effect:
		return
	is_recording = true
	recording_timer = MAX_RECORDING_TIME
	red_circle.visible = true
	red_circle.queue_redraw()
	status_label.text = "Status: Recording Audio..."
	record_effect.set_recording_active(true)
	if not audio_stream_record.playing:
		audio_stream_record.play()

func stop_ptt_recording_and_send() -> void:
	if not is_recording or not record_effect:
		return
	is_recording = false
	red_circle.visible = false
	record_effect.set_recording_active(false)
	status_label.text = "Status: Processing Audio..."

	var recording = record_effect.get_recording()
	if recording:
		# Process in RAM downsampled to 16kHz Mono 16-bit PCM (no disk writing)
		var wav_bytes = create_compact_16khz_wav_in_ram(recording)
		if wav_bytes.size() > 44:
			status_label.text = "Status: Audio processed in RAM (" + str(wav_bytes.size()) + " bytes)"
			var base64_audio = Marshalls.raw_to_base64(wav_bytes)
			send_audio_to_gemma(base64_audio)
		else:
			status_label.text = "Status: Error - recorded audio is empty"
	else:
		status_label.text = "Status: No audio recorded"

# Pure In-RAM Audio Processing: Downsamples AudioStreamWAV to 16kHz 16-bit Mono PCM RIFF WAV
func create_compact_16khz_wav_in_ram(sample: AudioStreamWAV) -> PackedByteArray:
	var raw_data = sample.data
	if raw_data.size() == 0:
		return PackedByteArray()

	var orig_mix_rate = sample.mix_rate
	if orig_mix_rate <= 0:
		orig_mix_rate = 44100

	var is_stereo = sample.stereo
	var target_mix_rate = 16000
	var step = float(orig_mix_rate) / float(target_mix_rate)

	var pcm_16_mono = PackedByteArray()

	# Process 16-bit PCM input data into 16kHz mono samples in RAM
	var num_samples = raw_data.size() / (4 if is_stereo else 2)
	var i: float = 0.0

	while i < num_samples:
		var idx = int(i)
		var byte_offset = idx * (4 if is_stereo else 2)
		if byte_offset + 1 < raw_data.size():
			var sample_val = raw_data.decode_s16(byte_offset)
			var offset_end = pcm_16_mono.size()
			pcm_16_mono.resize(offset_end + 2)
			pcm_16_mono.encode_s16(offset_end, sample_val)
		i += step

	var data_size = pcm_16_mono.size()
	var total_file_size = data_size + 36

	# Build 44-byte RIFF WAV Header in RAM
	var header = PackedByteArray()
	header.resize(44)

	# "RIFF"
	header[0] = 82; header[1] = 73; header[2] = 70; header[3] = 70
	header.encode_s32(4, total_file_size)
	# "WAVE"
	header[8] = 87; header[9] = 65; header[10] = 86; header[11] = 69
	# "fmt "
	header[12] = 102; header[13] = 109; header[14] = 116; header[15] = 32
	header.encode_s32(16, 16) # Subchunk1Size (16 for PCM)
	header.encode_s16(20, 1)  # AudioFormat (1 for PCM)
	header.encode_s16(22, 1)  # NumChannels (1 for Mono)
	header.encode_s32(24, target_mix_rate) # SampleRate (16000 Hz)
	header.encode_s32(28, target_mix_rate * 2) # ByteRate (16000 * 1 * 2)
	header.encode_s16(32, 2)  # BlockAlign (1 * 2 bytes)
	header.encode_s16(34, 16) # BitsPerSample (16 bits)
	# "data"
	header[36] = 100; header[37] = 97; header[38] = 116; header[39] = 97
	header.encode_s32(40, data_size)

	header.append_array(pcm_16_mono)
	return header

func send_audio_to_gemma(base64_audio: String) -> void:
	status_label.text = "Status: Sending to Gemma..."
	ai_response_label.text = "Thinking..."

	var url = format_http_url(server_url, "/v1/chat/completions")
	var headers = ["Content-Type: application/json"]

	var system_content = persona
	if pseudo_memory.strip_edges() != "":
		system_content += "\n\nPrevious Conversation Pseudo-Memory:\n" + pseudo_memory

	var payload = {
		"messages": [
			{
				"role": "system",
				"content": system_content
			},
			{
				"role": "user",
				"content": [
					{
						"type": "input_audio",
						"input_audio": {
							"data": base64_audio,
							"format": "wav"
						}
					},
					{
						"type": "text",
						"text": "Listen to the provided voice command audio carefully and respond to it."
					}
				]
			}
		]
	}

	var json_body = JSON.stringify(payload)
	var err = http_request.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		status_label.text = "Status: Request failed to send (" + str(err) + ")"
		ai_response_label.text = "Failed to connect to " + url

func _on_test_connection_pressed() -> void:
	status_label.text = "Status: Testing connection..."
	var url = format_http_url(server_url, "/v1/chat/completions")
	var headers = ["Content-Type: application/json"]

	var payload = {
		"messages": [
			{
				"role": "system",
				"content": persona
			},
			{
				"role": "user",
				"content": "hi what is your name?"
			}
		]
	}

	var json_body = JSON.stringify(payload)
	var err = http_request.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		status_label.text = "Status: Test request failed (" + str(err) + ")"

func _on_http_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var err_msg = body.get_string_from_utf8()
		status_label.text = "Status: HTTP Error " + str(response_code)
		if err_msg != "":
			print("HTTP Error Response: ", err_msg)
			ai_response_label.text = "Error " + str(response_code) + ": " + err_msg
		else:
			ai_response_label.text = "Error received from server: HTTP " + str(response_code)
		return

	var json = JSON.new()
	var parse_err = json.parse(body.get_string_from_utf8())
	if parse_err == OK and json.data is Dictionary:
		var response_dict = json.data
		var reply_text = ""

		if response_dict.has("choices") and response_dict["choices"].size() > 0:
			var choice = response_dict["choices"][0]
			if choice.has("message") and choice["message"].has("content"):
				reply_text = choice["message"]["content"]

		if reply_text != "":
			status_label.text = "Status: Response received"
			ai_response_label.text = reply_text
			speak_tts(reply_text)
			update_pseudo_memory(reply_text)
		else:
			status_label.text = "Status: Empty response content"
	else:
		status_label.text = "Status: Failed to parse JSON response"

func speak_tts(text: String) -> void:
	var voices = DisplayServer.tts_get_voices()
	if voices.size() > 0:
		var voice_id = voices[0]["id"]
		DisplayServer.tts_stop()
		DisplayServer.tts_speak(text, voice_id)

func update_pseudo_memory(latest_reply: String) -> void:
	if pseudo_memory == "":
		pseudo_memory = "Summary: " + latest_reply
	else:
		pseudo_memory += " | " + latest_reply
	memory_text_edit.text = pseudo_memory

func _on_clear_memory_pressed() -> void:
	pseudo_memory = ""
	memory_text_edit.text = ""
	status_label.text = "Status: Pseudo-Memory Cleared"

func _on_mic_selected(index: int) -> void:
	var dev_name = mic_option_button.get_item_text(index)
	AudioServer.set_input_device(dev_name)
	selected_mic = dev_name
	save_settings()

func _on_ip_changed(new_text: String) -> void:
	server_url = new_text.strip_edges()
	save_settings()

func _on_persona_changed() -> void:
	persona = persona_text_edit.text
	save_settings()

func format_http_url(ip_port_or_url: String, default_endpoint: String) -> String:
	var clean = ip_port_or_url.strip_edges()
	if not clean.begins_with("http://") and not clean.begins_with("https://"):
		clean = "http://" + clean
	if clean.ends_with("/"):
		clean = clean.substr(0, clean.length() - 1)
	if clean.contains("/v1/") or clean.contains("/completion") or clean.contains("/speech"):
		return clean
	return clean + default_endpoint

func save_settings() -> void:
	var config = ConfigFile.new()
	config.set_value("network", "server_url", server_url)
	config.set_value("audio", "microphone", selected_mic)
	config.set_value("ai", "persona", persona)
	config.save(SETTINGS_FILE)

func load_settings() -> void:
	var config = ConfigFile.new()
	var err = config.load(SETTINGS_FILE)
	if err == OK:
		server_url = config.get_value("network", "server_url", "192.168.15.71:8080")
		selected_mic = config.get_value("audio", "microphone", "")
		persona = config.get_value("ai", "persona", "You are a helpful and polite AI assistant.")

	ip_line_edit.text = server_url
	persona_text_edit.text = persona

	if selected_mic != "":
		var devices = AudioServer.get_input_device_list()
		for i in range(devices.size()):
			if devices[i] == selected_mic:
				mic_option_button.select(i)
				AudioServer.set_input_device(selected_mic)
				break

func update_ui_elements() -> void:
	ip_line_edit.text = server_url
	persona_text_edit.text = persona
	memory_text_edit.text = pseudo_memory
