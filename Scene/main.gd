extends Node

@export var autoStart := true;
@export_range(1,60,1) var updateFrequency := 60;
@export_file(".glsl") var computeShader: String;
@export var renderer : TextureRect;
@export var size : Vector2i = Vector2i(1920,1920)

var rd : RenderingDevice;
var workgroups_x: int
var workgroups_y: int

var dataTexture : Texture2D;
var inputTexture : RID;
var outputTexture : RID;
var uniformSet : RID;
var shader : RID;
var pipeline : RID;
var inputUniform : RDUniform
var outputUniform : RDUniform
var bindings : Array
var DefaultTextureFormat : RDTextureFormat
var inputImage : Image
var outputImage : Image
var renderTexture : ImageTexture

@onready var button = get_node("UI/Button")
@onready var slider = get_node("UI/HSlider")
@onready var label = get_node("UI/Label")
var is_gpu_work_pending = false
var processing : bool
var dragging_slider = false

var textureUsage = (
	RenderingDevice.TextureUsageBits.TEXTURE_USAGE_STORAGE_BIT
	| RenderingDevice.TextureUsageBits.TEXTURE_USAGE_CAN_UPDATE_BIT
	| RenderingDevice.TextureUsageBits.TEXTURE_USAGE_CAN_COPY_FROM_BIT
)


func _ready() -> void:
	_setup_images()
	_setup_shader()

	if(autoStart):
		button.set_pressed(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST || what == NOTIFICATION_PREDELETE:
		_cleanup_GPU()


func _cleanup_GPU():
	if(rd == null): return;
	processing = false
	rd.free_rid(inputTexture)
	rd.free_rid(outputTexture)
	rd.free_rid(uniformSet)
	rd.free_rid(shader)
	rd.free_rid(pipeline)
	rd.free()
	rd = null


###################################
# Setup
###################################

func _setup_images():
	DefaultTextureFormat = RDTextureFormat.new()
	DefaultTextureFormat.width = size.x
	DefaultTextureFormat.height = size.y
	DefaultTextureFormat.format = RenderingDevice.DataFormat.DATA_FORMAT_R8_UNORM
	DefaultTextureFormat.usage_bits = textureUsage
	outputImage = Image.create(DefaultTextureFormat.width, DefaultTextureFormat.height, false, Image.Format.FORMAT_L8)
	if dataTexture == null:
		var noise : FastNoiseLite = FastNoiseLite.new()
		noise.frequency = 0.1
		var noiseImage: Image = noise.get_image(DefaultTextureFormat.width, DefaultTextureFormat.height)
		inputImage = noiseImage
	else:
		inputImage = dataTexture.get_image()
	outputImage.copy_from(inputImage)
	renderTexture = ImageTexture.create_from_image(outputImage);
	renderTexture.update(outputImage)
	
	var mat : ShaderMaterial = renderer.material
	mat.set_shader_parameter("binaryDataTexture", renderTexture)
	mat.set_shader_parameter("gridWidth", size.x)
	mat.set_shader_parameter("gridHeight", size.y)


func _setup_shader():
	rd = RenderingServer.create_local_rendering_device()
	var shaderFile : RDShaderFile = load(computeShader)
	var spirV = shaderFile.get_spirv();
	shader = rd.shader_create_from_spirv(spirV)
	pipeline = rd.compute_pipeline_create(shader)

	inputTexture = _create_textures(inputImage, DefaultTextureFormat, 0)
	outputTexture = _create_textures(outputImage, DefaultTextureFormat, 1)
	_create_size_buffer(size.x, size.y , 2)

	uniformSet = rd.uniform_set_create(bindings, shader, 0)
	workgroups_x = int(ceil(size.x / 32.0))
	workgroups_y = int(ceil(size.y / 32.0))


func _create_textures(image: Image, format: RDTextureFormat, binding: int):
	var view = RDTextureView.new();
	var data: Array[PackedByteArray] = [image.get_data()]
	var texture = rd.texture_create(format,view,data)
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	bindings.append(uniform)
	return texture


func _create_size_buffer(width: int, height: int, binding: int):
	var buffer_data = PackedByteArray()
	# 16 instead of 8 because std140 mandates it so
	buffer_data.resize(16)
	buffer_data.encode_s32(0, width)
	buffer_data.encode_s32(4, height)

	var buffer = rd.uniform_buffer_create(buffer_data.size(), buffer_data)
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	bindings.append(uniform)


###################################
# Loop
###################################

func _start_compute_loop():
	var frequency : float = 1.0 / updateFrequency
	processing = true
	rd.texture_update(inputTexture, 0, outputImage.get_data())
	while(processing):
		_update();
		await get_tree().create_timer(frequency).timeout
		if(processing):
			_render()


func _update():
	if(is_gpu_work_pending): return;
	var computeList = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(computeList, pipeline)
	rd.compute_list_bind_uniform_set(computeList, uniformSet, 0)
	rd.compute_list_dispatch(computeList, workgroups_x, workgroups_y, 1)
	rd.compute_list_end()
	rd.submit()
	is_gpu_work_pending = true;


func _render():
	rd.sync()
	var bytes := rd.texture_get_data(outputTexture,0)
	outputImage.set_data(size.x, size.y, false, Image.Format.FORMAT_L8, bytes)
	rd.texture_update(inputTexture, 0, outputImage.get_data())
	renderTexture.update(outputImage)
	is_gpu_work_pending = false


###################################
# UI
###################################

func _on_button_toggled(toggled_on: bool) -> void:
	if(toggled_on):
		button.text = "Stop"
		if(is_gpu_work_pending):
			rd.sync()
			is_gpu_work_pending = false
		_start_compute_loop()
	else:
		button.text = "Start"
		processing = false


var last_coords
func _input(event: InputEvent) -> void:
	# On Key SPACE pressed
	if event is InputEventKey and event.physical_keycode == KEY_SPACE and event.is_pressed():
		button.set_pressed(!button.is_pressed())
		return

	if(processing || dragging_slider): return

	# Drawing input
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		if !event.is_pressed() && event.button_mask == 0:
			last_coords = null
		elif event.button_mask == MOUSE_BUTTON_MASK_LEFT:
			var local_mouse_pos = renderer.get_local_mouse_position()
			var renderer_size =  renderer.get_rect().size * 1/renderer.scale
			var cell_x = int(floor(local_mouse_pos.x / renderer_size.x * size.x))
			var cell_y = int(floor(local_mouse_pos.y / renderer_size.y * size.y))
			if cell_x >= 0 && cell_x < size.x && cell_y >= 0 && cell_y < size.y:
				var current_cell_coords = Vector2(cell_x, cell_y)
				if last_coords != current_cell_coords:
					last_coords = current_cell_coords
					var current_pixel_color = outputImage.get_pixel(cell_x, cell_y)
					var new_color = Color.BLACK if current_pixel_color == Color.WHITE else Color.WHITE
					outputImage.set_pixel(cell_x, cell_y, new_color)
					renderTexture.update(outputImage)


func _on_h_slider_value_changed(value: float) -> void:
	renderer.scale = Vector2(value,value)
	label.text = "Zoom: " + str(value)


func _on_h_slider_drag_started() -> void:
	dragging_slider = true


func _on_h_slider_drag_ended(_value_changed: bool) -> void:
	dragging_slider = false
