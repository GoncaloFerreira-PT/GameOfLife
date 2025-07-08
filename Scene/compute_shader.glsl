#[compute]
#version 450

const vec4 aliveColor = vec4(1.0,1.0,1.0,1.0);
const vec4 deadColor = vec4(0.0,0.0,0.0,1.0);

layout (local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout (binding = 0, r8) uniform readonly image2D inputImage;
layout (binding = 1, r8) uniform writeonly image2D outputImage;
layout (binding = 2, std140) uniform Params {
    int gridWidth; 
    int gridHeight;
}params;


float get_pixel(ivec2 pos){
    return imageLoad(inputImage, pos).r;
}

bool is_alive(ivec2 pos){
    return get_pixel(pos) > 0.5f;
}

int check_neighbours(ivec2 pos){
	int total = 0;
    int x = pos.x;
    int y = pos.y;
	for(int i=-1; i < 2; i++){
       for(int j=-1; j < 2; j++){
        int indexX = (x+i);
		int indexY = (y+j);
        if (indexX >= 0 && indexX < params.gridWidth && indexY >= 0 && indexY < params.gridHeight){
            if (is_alive(ivec2(indexX, indexY))){
                total += 1;
            }
            }
        } 
    }

	//Ignore self
    if (is_alive(pos)){
        total -= 1;
    }

	return total;
}


void main(){
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= params.gridWidth || pos.y >= params.gridHeight) return;

    int live_neighbours = check_neighbours(pos);
    bool isAlive = is_alive(pos);
    bool nextState = isAlive;

	if (isAlive){
        //Any live cell with fewer than two live neighbours dies, as if by underpopulation.
		if (live_neighbours < 2){
            nextState = false;
        }
		//Any live cell with more than three live neighbours dies, as if by overpopulation.
		else if (live_neighbours > 3){
             nextState = false;
        }
        //Any live cell with two or three live neighbours lives on to the next generation
        else if (live_neighbours == 2 || live_neighbours == 3){
            nextState = true;
        }
    }
    //Any dead cell with exactly three live neighbours becomes a live cell, as if by reproduction.
	else if (live_neighbours == 3){
        nextState = true;
    }

    vec4 newColor = nextState ? aliveColor : deadColor;

    imageStore(outputImage, pos, newColor);
}