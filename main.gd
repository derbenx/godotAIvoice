extends Node3D

# Persistent settings
const SETTINGS_FILE = "user://settings.cfg"

var server_url: String = "192.168.15.71:8080"
var persona: String = "You are a helpful and polite AI assistant."
var selected_mic: String = ""

# In-memory session summary (not saved persistently)
var pseudo_memory: String = ""

# State variables
var is_recording: bool = false
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

func setup_audio_record_bus() -> void:
	record_bus_index = AudioServer.get_bus_index("Record")
	if record_bus_index == -1:
		AudioServer.add_bus()
		record_bus_index = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(record_bus_index, "Record")

	# Important: Bus must NOT be muted for AudioEffectRecord to capture audio in Godot!
	# We lower the volume to -80 dB to avoid output feedback through speakers.
	AudioServer.set_bus_mute(record_bus_index, false)
	AudioServer.set_bus_volume_db(record_bus_index, -80.0)

	if AudioServer.get_bus_effect_count(record_bus_index) == 0:
		var effect = AudioEffectRecord.new()
		AudioServer.add_bus_effect(record_bus_index, effect)

	record_effect = AudioServer.get_bus_effect(record_bus_index, 0) as AudioEffectRecord

func _on_red_circle_draw() -> void:
	if red_circle.visible:
		var center = red_circle.size / 2.0
		var radius = min(center.x, center.y) - 5.0
		red_circle.draw_circle(center, radius, Color.RED)

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
	if audio_stream_record.playing:
		audio_stream_record.stop()
	status_label.text = "Status: Processing Audio..."

	var recording = record_effect.get_recording()
	if recording:
		recording.save_to_wav("user://temp_recording.wav")
		var wav_bytes = FileAccess.get_file_as_bytes("user://temp_recording.wav")
		if wav_bytes.size() > 0:
			var base64_audio = Marshalls.raw_to_base64(wav_bytes)
			send_audio_to_gemma(base64_audio)
		else:
			status_label.text = "Status: Error saving recording"
	else:
		status_label.text = "Status: No audio recorded"

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
						"text": "Please reply to this audio voice command and also provide a concise summary of our interaction."
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
		status_label.text = "Status: HTTP Error " + str(response_code)
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

func format_http_url(ip_port: String, endpoint: String) -> String:
	var clean = ip_port.strip_edges()
	if not clean.begins_with("http://") and not clean.begins_with("https://"):
		clean = "http://" + clean
	if clean.ends_with("/"):
		clean = clean.substr(0, clean.length() - 1)
	return clean + endpoint

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
