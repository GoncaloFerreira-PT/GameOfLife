shader_type canvas_item;

uniform sampler2D binaryDataTexture;
uniform float gridWidth;
uniform float gridHeight;


void fragment() {
	vec2 scaledUV = vec2(UV.x * gridWidth, UV.y * gridHeight);
	ivec2 cellIndex = ivec2(floor(scaledUV));
	vec2 binaryDataUV = (vec2(cellIndex) + 0.5) / vec2(gridWidth, gridHeight);
	
	float binaryValue = texture(binaryDataTexture, binaryDataUV).r;
	
	bool isWhite = binaryValue == 1.0;
	float alpha = 1.0;
	if(!isWhite)
		alpha = 0.0;
		
	COLOR = vec4(1.0,1.0,1.0,alpha);
}