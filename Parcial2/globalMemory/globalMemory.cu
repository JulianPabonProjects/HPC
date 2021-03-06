#include<iostream>
#include<stdio.h>
#include<malloc.h>
#include<opencv2/opencv.hpp>
using namespace std;
using namespace cv;

#define RED 2
#define GREEN 1
#define BLUE 0


__device__
__host__
unsigned char clamp(int value){
  if (value < 0) value = 0;
  if (value > 255) value = 255;
  return (unsigned char)value;
}

__host__
void print(unsigned char *M, int rows, int cols){
  for (int i = 0; i < rows; i++) {
    for (int j = 0; j < cols; j++) {
      printf("%d ", M[(i * cols) + j]);
    }
    printf("\n");
  }
}

__host__
void convolution(unsigned char *imageInput, int mask[3][3], int rows, int cols, unsigned char *imageOutput){

  for(int i = 0; i < rows; i++) {
    for(int j = 0; j < cols; j++) {
      int sum = 0;
      int aux_cols = j - 1, aux_rows = i - 1;

      for(int k = 0; k < 3; k++) { //mask_filas
        for(int l = 0; l < 3; l++) { //mask_columnas
          if ((aux_rows >= 0 && aux_cols >= 0) && (aux_rows < rows && aux_cols < cols))

          sum += mask[k][l]*imageInput[(aux_rows*cols)+ aux_cols];

          aux_cols++;
        }
        aux_rows++;
        aux_cols = j - 1;
      }

      imageOutput[(i * cols) + j] = clamp(sum);
    }
  }
}

__global__
void convolutionCU(unsigned char *imageInput, int *mask, int rows, int cols, unsigned char *imageOutput){

  int i = blockIdx.y*blockDim.y+threadIdx.y;
  int j = blockIdx.x*blockDim.x+threadIdx.x;
  int sum = 0;

  if (i < rows && j < cols) {

    int aux_cols = j - 1, aux_rows = i - 1;
    for (int k = 0; k < 3; k++) {//mask_filas
      for (int l = 0; l < 3; l++) {//mask_columnas
        if(aux_rows >= 0 && aux_cols >= 0 && aux_rows < rows && aux_cols < cols)
        sum += mask[(k*3) + l] * imageInput[(aux_rows*cols) + aux_cols];

        aux_cols++;
      }
      aux_rows++;
      aux_cols = j - 1;
    }
    imageOutput[(i * cols) + j] = clamp(sum);
  }
}


__host__
void img2gray(unsigned char *imageInput, int width, int height, unsigned char *imageOutput){

  for(int row = 0; row < height; row++){
    for(int col = 0; col < width; col++){
      imageOutput[row*width+col] = imageInput[(row*width+col)*3+RED]*0.299 + imageInput[(row*width+col)*3+GREEN]*0.587 + imageInput[(row*width+col)*3+BLUE]*0.114;
    }
  }
}


__global__
void img2grayCU(unsigned char *imageInput, int width, int height, unsigned char *imageOutput){

  int row = blockIdx.y*blockDim.y+threadIdx.y;
  int col = blockIdx.x*blockDim.x+threadIdx.x;

  if((row < height) && (col < width)){

    imageOutput[row*width+col] = imageInput[(row*width+col)*3+RED]*0.299 + imageInput[(row*width+col)*3+GREEN]*0.587
    + imageInput[(row*width+col)*3+BLUE]*0.114;
  }
}


__host__
void Union(unsigned char *imageOutput, unsigned char *Gx, unsigned char *Gy, int rows, int cols){
  for(int i = 0; i < rows; i++){
    for(int j = 0; j < cols; j++){
      imageOutput[(i * cols) + j] = sqrt(pow(Gx[(i * cols) + j],2) + pow(Gx[(i * cols) + j],2));
    }
  }
}


__global__
void UnionCU(unsigned char *imageOutput, unsigned char *Gx, unsigned char *Gy, int rows, int cols){

  int i = blockIdx.y*blockDim.y+threadIdx.y;
  int j = blockIdx.x*blockDim.x+threadIdx.x;

  if (i < rows && j < cols){
    imageOutput[(i * cols) + j] = sqrtf((Gx[(i * cols) + j] * Gx[(i * cols) + j]) + (Gx[(i * cols) + j] * Gx[(i * cols) + j]) );
  }
}

int main(int argc, char **argv){

  cudaError_t error = cudaSuccess;
  unsigned char *h_imageInput, *d_imageInput, *h_imageGray, *d_imageGray;
  unsigned char *d_Gx, *d_Gy, *h_G, *d_G; // Operacion sobel
  int *d_XMask, *d_YMask;
  char* imageName = argv[1];
  char* contImage = argv[2];
  Mat image;

  clock_t start, end;
  double time_used;

  if (argc != 3) {
    printf("Usage: Image path\n");
    return 1;
  }

  image = imread(imageName, 1);

  if (!image.data) {
    printf("No image Data\n");
    return 1;
  }

  //---------> Grises

  Size s = image.size();

  int width = s.width;
  int height = s.height;
  int sz = sizeof(unsigned char) * width * height * image.channels();
  int size = sizeof(unsigned char) * width * height;


  h_imageInput = (unsigned char*)malloc(sz);

  error = cudaMalloc((void**)&d_imageInput,sz);
  if (error != cudaSuccess) {
    printf("Error allocating memory for d_imageInput\n");
    exit(-1);
  }

  h_imageInput = image.data;

  start = clock();

  error = cudaMemcpy(d_imageInput, h_imageInput, sz, cudaMemcpyHostToDevice);
  if (error != cudaSuccess) {
    printf("Error copying data from h_imageInput to d_imageInput\n");
    exit(-1);
  }

  end = clock();
  time_used = ((double) (end - start)) /CLOCKS_PER_SEC;


  h_imageGray = (unsigned char*)malloc(size);

  error = cudaMalloc((void**)&d_imageGray, size);
  if (error != cudaSuccess) {
    printf("Error allocating memory for d_imageGray\n");
    exit(-1);
  }


  start = clock();

  int blockSize = 32;
  dim3 dimBlock(blockSize, blockSize, 1);
  dim3 dimGrid(ceil(width/float(blockSize)), ceil(height/float(blockSize)), 1);
  img2grayCU<<<dimGrid,dimBlock>>>(d_imageInput, width, height, d_imageGray);
  cudaDeviceSynchronize();

  end = clock();
  time_used += ((double) (end - start)) /CLOCKS_PER_SEC;


  //---------> Mascaras

  error = cudaMalloc((void**)&d_XMask, 3*3*sizeof(int));
  if (error != cudaSuccess) {
    printf("Error reservando memoria para d_Mascara_X\n");
    exit(-1);
  }

  error = cudaMalloc((void**)&d_YMask, 3*3*sizeof(int));
  if (error != cudaSuccess) {
    printf("Error reservando memoria para d_Mascara_Y\n");
    exit(-1);
  }

  int h_XMask[3*3] = {-1, 0, 1, -2, 0, 2, -1, 0, 1};
  int h_YMask[3*3] = {-1, -2, -1, 0, 0, 0, 1, 2, 1};


  start = clock();

  error = cudaMemcpy(d_XMask, h_XMask, 3*3*sizeof(int), cudaMemcpyHostToDevice);
  if (error != cudaSuccess) {
    printf("Error copying data from h_XMask to d_XMask\n");
    exit(-1);
  }

  error = cudaMemcpy(d_YMask, h_YMask, 3*3*sizeof(int), cudaMemcpyHostToDevice);
  if(error != cudaSuccess){
    printf("Error copying data from h_YMask to d_YMask\n");
    exit(-1);
  }

  end = clock();
  time_used += ((double) (end - start)) /CLOCKS_PER_SEC;

  //---------> Sobel

  h_G = (unsigned char*)malloc(size);

  error = cudaMalloc((void**)&d_G, size);
  if (error != cudaSuccess) {
    printf("Error allocating memory for d_G\n");
    exit(-1);
  }

  error = cudaMalloc((void**)&d_Gx, size);
  if (error != cudaSuccess) {
    printf("Error allocating memory for d_Gx\n");
    exit(-1);
  }

  error = cudaMalloc((void**)&d_Gy, size);
  if (error != cudaSuccess) {
    printf("Error allocating memory for d_Gy\n");
    exit(-1);
  }


  start = clock();

  // Convolucion en Gx

  convolutionCU<<<dimGrid,dimBlock>>>(d_imageGray, d_XMask, height, width, d_Gx);
  cudaDeviceSynchronize();

  // Convolucion en Gy
  convolutionCU<<<dimGrid,dimBlock>>>(d_imageGray, d_YMask, height, width, d_Gy);
  cudaDeviceSynchronize();

  // Union of Gx and Gy results
  UnionCU<<<dimGrid,dimBlock>>>(d_G, d_Gx, d_Gy, height, width);
  cudaDeviceSynchronize();

  error = cudaMemcpy(h_G, d_G, size, cudaMemcpyDeviceToHost);
  if (error != cudaSuccess) {
    printf("Error copying data from d_G to h_G\n");
    exit(-1);
  }

  end = clock();
  time_used += ((double) (end - start)) /CLOCKS_PER_SEC;

    //crea la imagen resultante
  Mat result_img;
  result_img.create(height, width, CV_8UC1);
  result_img.data = h_G;
  string nameImage = "./imgOut/imgR"+ string(contImage) +".jpg";

   imwrite(nameImage, result_img);

  printf ("%lf \n",time_used);


  free(h_imageInput);
  cudaFree(d_imageInput);
  free(h_imageGray);
  cudaFree(d_imageGray);
  cudaFree(d_XMask);
  cudaFree(d_YMask);
  free(h_G);
  cudaFree(d_Gx);
  cudaFree(d_Gy);
  cudaFree(d_G);

  return 0;
}
