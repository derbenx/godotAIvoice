extends Node3D

# Persistent settings
const SETTINGS_FILE = "user://settings.cfg"
const MIN_RECORDING_TIME: float = 2.0
const MAX_RECORDING_TIME: float = 20.0
const SILENCE_THRESHOLD: float = 10.0 # RMS threshold for detecting silent audio

var server_url: String = "192.168.15.71:8080"
var persona: String = "You are a helpful and polite AI assistant. The user speaks to you using audio voice commands."
var selected_mic: String = ""

# In-memory session summary (not saved persistently)
var pseudo_memory: String = ""

# State variables
var is_recording: bool = false
var pending_stop: bool = false
var recording_timer: float = 0.0
var elapsed_recording_time: float = 0.0
var record_effect: AudioEffectRecord = null
var record_bus_index: int = -1
var is_vr_mode: bool = false
var turn_count: int = 0

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

func _notification(what: int) -> void:
	# Prevent B button / Back button on Android/Quest from closing the app
	if what == NOTIFICATION_WM_GO_BACK_REQUEST or what == NOTIFICATION_WM_BACK_NAVIGATION:
		toggle_settings_menu()

func _ready() -> void:
	# Initialize OpenXR if available
	var xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface:
		if not xr_interface.is_initialized():
			xr_interface.initialize()
		if xr_interface.is_initialized():
			print("OpenXR initialized successfully. Enabling VR mode.")
			get_viewport().use_xr = true
			is_vr_mode = true
		else:
			print("OpenXR interface present but failed to initialize. PC mode.")
	else:
		print("OpenXR interface not found. Falling back to PC mode.")

	# Setup Audio Recording Bus
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
		elapsed_recording_time += delta
		red_circle.queue_redraw()

		# Check 20s maximum limit or pending stop after reaching 2s minimum
		if recording_timer <= 0.0 or (pending_stop and elapsed_recording_time >= MIN_RECORDING_TIME):
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

func _on_red_circle_draw() -> void:
	if red_circle.visible:
		var center = red_circle.size / 2.0
		var radius = min(center.x, center.y) - 5.0
		red_circle.draw_circle(center, radius, Color(0.9, 0.1, 0.1, 0.9))

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
		toggle_settings_menu()

	# Push To Talk handling
	if event.is_action_pressed("ptt"):
		start_ptt_recording()
	elif event.is_action_released("ptt"):
		on_ptt_released()

func toggle_settings_menu() -> void:
	menu_panel.visible = !menu_panel.visible
	if menu_panel.visible:
		ip_line_edit.grab_focus()
		position_vr_menu_if_needed()

func _input(event: InputEvent) -> void:
	# Check spacebar / PTT event if not handled or when UI controls have focus
	if event.is_action_pressed("ptt") and not is_recording:
		if event is InputEventKey and event.keycode == KEY_SPACE:
			var focused = get_viewport().gui_get_focus_owner()
			if focused is LineEdit or focused is TextEdit:
				return # Don't record when typing text into LineEdit/TextEdit
			start_ptt_recording()
	elif event.is_action_released("ptt") and is_recording:
		on_ptt_released()

func position_vr_menu_if_needed() -> void:
	if is_vr_mode and xr_camera:
		var cam_transform = xr_camera.global_transform
		vr_menu_3d.global_transform.origin = cam_transform.origin + cam_transform.basis.z * -1.5
		vr_menu_3d.look_at(cam_transform.origin, Vector3.UP)
		vr_menu_3d.rotate_y(PI)

func start_ptt_recording() -> void:
	if is_recording:
		return
	is_recording = true
	pending_stop = false
	recording_timer = MAX_RECORDING_TIME
	elapsed_recording_time = 0.0
	turn_count += 1
	red_circle.visible = true
	red_circle.queue_redraw()
	status_label.text = "Status: Turn " + str(turn_count) + " - Recording Audio..."

	# Completely refresh AudioStreamPlayer & AudioStreamMicrophone
	if audio_stream_record.playing:
		audio_stream_record.stop()
	audio_stream_record.stream = AudioStreamMicrophone.new()

	# Re-create a fresh AudioEffectRecord instance for this turn
	while AudioServer.get_bus_effect_count(record_bus_index) > 0:
		AudioServer.remove_bus_effect(record_bus_index, 0)

	record_effect = AudioEffectRecord.new()
	AudioServer.add_bus_effect(record_bus_index, record_effect)

	audio_stream_record.play()
	record_effect.set_recording_active(true)

func on_ptt_released() -> void:
	if not is_recording:
		return

	if elapsed_recording_time >= MIN_RECORDING_TIME:
		stop_ptt_recording_and_send()
	else:
		pending_stop = true
		status_label.text = "Status: Turn " + str(turn_count) + " - Completing min 2s recording..."

func stop_ptt_recording_and_send() -> void:
	if not is_recording or not record_effect:
		return
	is_recording = false
	pending_stop = false
	red_circle.visible = false
	record_effect.set_recording_active(false)

	if audio_stream_record.playing:
		audio_stream_record.stop()

	status_label.text = "Status: Turn " + str(turn_count) + " - Checking Audio..."

	var recording = record_effect.get_recording()
	if not recording:
		status_label.text = "Status: Turn " + str(turn_count) + " - Error: Null audio recording object"
		ai_response_label.text = "No audio object captured from microphone."
		return

	if not recording.data or recording.data.size() == 0:
		status_label.text = "Status: Turn " + str(turn_count) + " - Error: Empty audio data buffer"
		ai_response_label.text = "Microphone buffer is empty."
		return

	var max_amplitude = calculate_max_amplitude(recording.data)
	print("Captured recording data size: ", recording.data.size(), " bytes | Max amplitude: ", max_amplitude)

	if max_amplitude < SILENCE_THRESHOLD:
		status_label.text = "Status: Turn " + str(turn_count) + " - Silent audio detected (Amp: " + str(int(max_amplitude)) + ")"
		ai_response_label.text = "Audio recording was silent or null. Please check your microphone selection."
		return

	var wav_bytes = create_compact_16khz_wav_in_ram(recording)
	if wav_bytes.size() > 44:
		status_label.text = "Status: Turn " + str(turn_count) + " - Audio valid (" + str(wav_bytes.size()) + " bytes, Amp: " + str(int(max_amplitude)) + ")"
		var base64_audio = Marshalls.raw_to_base64(wav_bytes)
		send_audio_to_gemma(base64_audio)
	else:
		status_label.text = "Status: Turn " + str(turn_count) + " - Error: Invalid WAV header/data"

# Returns peak amplitude to detect silent / null audio
func calculate_max_amplitude(raw_bytes: PackedByteArray) -> float:
	var peak: float = 0.0
	var total_bytes = raw_bytes.size()
	var step_bytes = 20
	var offset = 0
	while offset + 1 < total_bytes:
		var val = abs(raw_bytes.decode_s16(offset))
		if val > peak:
			peak = val
		offset += step_bytes
	return peak

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

	var header = PackedByteArray()
	header.resize(44)

	# "RIFF"
	header[0] = 82; header[1] = 73; header[2] = 70; header[3] = 70
	header.encode_s32(4, total_file_size)
	# "WAVE"
	header[8] = 87; header[9] = 65; header[10] = 86; header[11] = 69
	# "fmt "
	header[12] = 102; header[13] = 109; header[14] = 116; header[15] = 32
	header.encode_s32(16, 16) # Subchunk1Size
	header.encode_s16(20, 1)  # AudioFormat (PCM)
	header.encode_s16(22, 1)  # NumChannels (Mono)
	header.encode_s32(24, target_mix_rate) # SampleRate (16000 Hz)
	header.encode_s32(28, target_mix_rate * 2) # ByteRate
	header.encode_s16(32, 2)  # BlockAlign
	header.encode_s16(34, 16) # BitsPerSample (16 bits)
	# "data"
	header[36] = 100; header[37] = 97; header[38] = 116; header[39] = 97
	header.encode_s32(40, data_size)

	header.append_array(pcm_16_mono)
	return header

func send_audio_to_gemma(base64_audio: String) -> void:
	status_label.text = "Status: Turn " + str(turn_count) + " - Sending to Gemma..."
	ai_response_label.text = "Thinking..."

	var url = format_http_url(server_url, "/v1/chat/completions")
	var headers = ["Content-Type: application/json"]

	var system_content = persona + "\n\nCRITICAL INSTRUCTION: The user's message always contains new spoken audio in the 'input_audio' field. Listen to the audio and reply directly."
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
						"text": "Here is my audio voice command for turn " + str(turn_count) + ". Please answer my question."
					}
				]
			}
		]
	}

	var json_body = JSON.stringify(payload)
	var err = http_request.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		status_label.text = "Status: Request failed (" + str(err) + ")"
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
			status_label.text = "Status: Turn " + str(turn_count) + " - Response received"
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
	turn_count = 0
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
