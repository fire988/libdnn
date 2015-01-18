// Copyright 2013-2014 [Author: Po-Wei Chou]
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <feature-transform.h>
#include <cnn-utility.h>
#include <cuda_profiler_api.h>
using namespace std;

#define DEBUG_STR(x) ("\33[33m"#x"\33[0m = " + to_string(x) + "\t")
#define MAX_SHARED_MEMORY_SIZE (48 * 1024)

#define VECTOR std::vector
#define WHERE std
#include <operators.inl>
#undef VECTOR
#undef WHERE

#define __CUDA_CONSTANTS__ \
  const int nThreads = blockDim.x * blockDim.y;\
  const int tx = threadIdx.x;\
  const int ty = threadIdx.y;\
  int tid = tx + blockDim.x * ty;\
  int x0 = blockIdx.x * blockDim.x;\
  int y0 = blockIdx.y * blockDim.y;\
  const int x = x0 + tx;\
  const int y = y0 + ty;

/*! Convert each row to a 2D image
 * \param data Each col in data is a feature vector. # of cols = # of data
						     # of rows = image size
 * \param s Size of the image. # of rows in data = s.m x s.n
 */
vector<mat> reshapeVectors2Images(const mat& data, const SIZE s) {

  size_t nData = data.getCols();
  vector<mat> images(nData);

  for (size_t i=0; i<nData; ++i) {
    images[i].resize(s.m, s.n);

    CCE(cudaMemcpy(images[i].getData(), data.getData() + i * data.getRows(),
	  sizeof(float) * s.m * s.n, cudaMemcpyDeviceToDevice));
  }
  CCE(cudaDeviceSynchronize());

  return images;
}

template <bool rot180kernel>
__device__ void load_kernel_into_shm(float* const K, const float* const kernel,
    int kH, int kW, int tid, int nThreads) {

  // Copy kernel in global memory to shared memory
  for (; tid<kW * kH; tid += nThreads) {
    int xx = tid / kH,
	yy = tid % kH;

    if (xx >= kW || yy >= kH) continue;

    if (rot180kernel)
      K[xx * kH + yy] = kernel[xx * kH + yy];
    else
      K[(kW - 1 - xx) * kH + (kH - 1 - yy)] = kernel[xx * kH + yy];
  }
}

template <bool rot180data, bool rot180kernel>
__global__ void convn_valid_kernel_with_shm(
    float *output, const int vH, const int vW,
    const float *data, const int H, const int W,
    const float *kernel, const int kH, const int kW,
    const int output_step, const int data_step, const int kernel_step) {

  __CUDA_CONSTANTS__;

  output += blockIdx.z * output_step;
  data   += blockIdx.z * data_step;
  kernel += blockIdx.z * kernel_step;

  extern __shared__ float K[];

  // Copy kernel in global memory to shared memory
  load_kernel_into_shm<rot180kernel>(K, kernel, kH, kW, tid, nThreads);

  // Copy data in global memory to shared memory
  float* D = K + kW * kH;
  int WIDTH_STEP = blockDim.x + kW - 1,
      HEIGHT_STEP = blockDim.y + kH - 1;

  int nTotal = WIDTH_STEP * HEIGHT_STEP;

  for (; tid<nTotal; tid += nThreads) {
    int xx = tid / HEIGHT_STEP + x0,
	yy = tid % HEIGHT_STEP + y0;

    if (xx >= W || yy >= H) continue;

    // rotate data 180 degree
    if (rot180data)
      D[tid] = data[ (W - 1 - xx) * H + (H - 1 - yy) ];
    else
      D[tid] = data[ xx * H + yy ];
  }
  __syncthreads();

  if (x >= vW || y >= vH)
    return;

  float sum = 0;
  D += tx * HEIGHT_STEP + ty;
  for (int i = 0; i < kW; ++i)
    for(int j = 0; j < kH; ++j)
      sum += K[ i * kH + j ] * D[ i * HEIGHT_STEP + j ]; 

  output[ x * vH + y ] += sum;
} 

__global__ void convn_valid_kernel(float *output, float *data, float *kernel,
    const int H, const int W, const int kH, const int kW) { 

  // Matrix index
  int x = blockIdx.x*blockDim.x + threadIdx.x;
  int y = blockIdx.y*blockDim.y + threadIdx.y;

  // vH, vW stands for valid H and valid W
  const int vH = H - kH + 1,
	    vW = W - kW + 1;

  if (x >= vW || y >= vH)
    return;

  x += kW - 1;
  y += kH - 1;

  float sum = 0; 
  for (int i = 0; i < kW; ++i)
    for(int j = 0; j < kH; ++j)
      sum += kernel[ i * kH + j ] * data[ (x - i) * H + (y - j) ]; 

  x -= kW - 1;
  y -= kH - 1;

  output[ x * vH + y ] = sum;
} 

__global__ void convn_same_kernel(float *output, float *data, float *kernel,
    const int H, const int W, const int kH, const int kW) { 

  // Matrix index
  const int x = blockIdx.x*blockDim.x + threadIdx.x;
  const int y = blockIdx.y*blockDim.y + threadIdx.y;

  if (x >= W || y >= H)
    return;

  const int i0 = kW / 2, j0 = kH / 2;

  float sum = 0; 
  for (int i = 0; i < kW; ++i) {
    for(int j = 0; j < kH; ++j) {
      int ii = x - i + i0, jj = y - j + j0;

      if ( ii < 0 || ii >= W || jj < 0 || jj >= H )
	continue;

      sum += kernel[ i * kH + j ] * data[ ii * H + jj ]; 
    }
  }

  output[x * H + y] = sum;
} 

template <bool rot180data, bool rot180kernel>
__global__ void convn_full_kernel_with_shm(
    float *output, const int fH, const int fW,
    float *data, const int H, const int W,
    float *kernel, const int kH, const int kW,
    const int output_step, const int data_step, const int kernel_step) {

  __CUDA_CONSTANTS__;

  output += blockIdx.z * output_step;
  data   += blockIdx.z * data_step;
  kernel += blockIdx.z * kernel_step;

  extern __shared__ float K[];

  // Copy kernel in global memory to shared memory
  load_kernel_into_shm<rot180kernel>(K, kernel, kH, kW, tid, nThreads);

  // Copy data in global memory to shared memory
  float* D = K + kW * kH;
  const int WIDTH_STEP = blockDim.x + kW - 1;
  const int HEIGHT_STEP = blockDim.y + kH - 1;
  const int nTotal = WIDTH_STEP * HEIGHT_STEP;

  x0 -= (kW - 1);
  y0 -= (kH - 1);

  for (; tid<nTotal; tid += nThreads) {
    int xx = x0 + tid / HEIGHT_STEP,
	yy = y0 + tid % HEIGHT_STEP;

    if (xx < 0 || xx >= W || yy < 0 || yy >= H)
      D[tid] = 0;
    else  {
      if (rot180data)
	D[tid] = data[ (W - 1 - xx) * H + (H - 1 - yy) ];
      else
	D[tid] = data[ xx * H + yy ];
    }
  }
  __syncthreads();
  
  if (x >= fW || y >= fH)
    return;

  float sum = 0; 
  D += tx * HEIGHT_STEP + ty;
  for (int i = 0; i < kW; ++i)
    for(int j = 0; j < kH; ++j)
      sum += K[ i * kH + j ] * D[ i * HEIGHT_STEP + j]; 

  output[ x * fH + y ] += sum;
}

__global__ void convn_full_kernel(float *output, float *data, float *kernel,
    int H, int W, int kH, int kW) { 

  int tx = threadIdx.x;
  int ty = threadIdx.y;

  // Matrix index
  int x = blockIdx.x*blockDim.x + tx;
  int y = blockIdx.y*blockDim.y + ty;

  // fH, fW stands for full H and full W
  const int fH = H + kH - 1,
	    fW = W + kW - 1;

  if (x >= fW || y >= fH)
    return;

  float sum = 0; 
  for (int i = 0; i < kW; ++i) {
    for(int j = 0; j < kH; ++j) {
      int ii = x - i, jj = y - j;

      if ( ii < 0 || ii >= W || jj < 0 || jj >= H )
	continue;

      sum += kernel[ i * kH + j ] * data[ ii * H + jj ]; 
    }
  }

  output[ x * fH + y ] = sum;
}

SIZE get_convn_size(SIZE data, SIZE kernel, ConvType type) {
  switch (type) {
    case SAME:
    case SAME_SHM:
      return data;
    case VALID:
    case VALID_SHM:
      return max(data - kernel + 1, SIZE(0, 0));
    case FULL:
    case FULL_SHM:
      return data + kernel - 1;
    default:
      throw runtime_error(RED_ERROR + "Unknown type of convolution.");
  };
}

SIZE get_convn_size(const mat& data, const mat& kernel, ConvType type) {

  SIZE dSize(data.getRows(), data.getCols());
  SIZE kSize(kernel.getRows(), kernel.getCols());

  return get_convn_size(dSize, kSize, type);
}

size_t getSuitableShmConfig(dim3 &grids, dim3 &threads, int kH, int kW) {
  size_t SHM_SIZE = ( kW * kH + (threads.x + kW - 1) * (threads.y + kH - 1) ) * sizeof(float);

  while ( SHM_SIZE > MAX_SHARED_MEMORY_SIZE && threads.x * threads.y >= 32 ) {
    if ( threads.x >= threads.y ) {
      threads.x /= 2;
      grids.x *= 2;
    }
    else {
      threads.y /= 2;
      grids.y *= 2;
    }

    SHM_SIZE = ( kW * kH + (threads.x + kW - 1) * (threads.y + kH - 1) ) * sizeof(float);
  }
  cudaDeviceSetCacheConfig(cudaFuncCachePreferShared);

  if (SHM_SIZE > MAX_SHARED_MEMORY_SIZE) {
    char buf[512];
    sprintf(buf, "Exceeds maximum shared memory available. (%d bytes)\n"
	"kernel = (%d, %d), grids = (%u, %u, %u), threads = (%u, %u, %u) "
	" => %lu bytes of shared memory needed.", MAX_SHARED_MEMORY_SIZE, kH, kW,
	grids.x, grids.y, grids.z, threads.x, threads.y, threads.z, SHM_SIZE);
    throw runtime_error(RED_ERROR + to_string(buf));
  }

  return SHM_SIZE;
}

mat convn(const mat& data, const mat& kernel, ConvType type) {

  int H = data.getRows(),
      W = data.getCols(),
      kH = kernel.getRows(),
      kW = kernel.getCols();

  SIZE s = get_convn_size(data, kernel, type);

  mat output(s.m, s.n);
  ALLOCATE_GRIDS_AND_THREADS(output.getCols(), output.getRows());

  cudaStream_t stream = 0;

  switch (type) {
    case SAME:
      convn_same_kernel<<< grids, threads, 0, stream >>>(
	  output.getData(),
	  data.getData(),
	  kernel.getData(),
	  H, W, kH, kW);
      break;
    case SAME_SHM:
      // TODO
      break;
    case VALID:
      convn_valid_kernel<<< grids, threads, 0, stream >>>(
	  output.getData(),
	  data.getData(),
	  kernel.getData(),
	  H, W, kH, kW);
      break;
    case VALID_SHM:
      // TODO
    break;
    case FULL:
      convn_full_kernel<<< grids, threads, 0, stream >>>(
	  output.getData(),
	  data.getData(),
	  kernel.getData(),
	  H, W, kH, kW);
      break;
      
    case FULL_SHM:
      // TODO
    break;
    default:
      throw runtime_error(RED_ERROR + "Unknown convolution type");
  }

  CCE(cudaPeekAtLastError());
  CCE(cudaDeviceSynchronize());
  
  return output;
}

__global__ void downsample_kernel(float *dst, float *src, const uint8_t scale,
    const uint8_t H, const uint8_t W) { 
  // Matrix index
  uint16_t x = blockIdx.x*blockDim.x + threadIdx.x;
  uint16_t y = blockIdx.y*blockDim.y + threadIdx.y;

  const uint8_t h = H / scale;
  const uint8_t w = W / scale;

  if (y >= w || x >= h)
    return;

  dst += blockIdx.z * h * w + y * h + x;

  y *= scale;
  x *= scale;

  float sum = 0;

  src += blockIdx.z * H * W + y * H + x;

  for (uint8_t i=0; i<scale; ++i) {
    for (uint8_t j=0; j<scale; ++j) {
      if ( y + i < W && x + j < H )
	sum += src[i * H + j];
    }
  }

  *dst = sum / (scale * scale);
}

__global__ void upsample_kernel(float *dst, float *src, const uint8_t h,
    const uint8_t w, const uint8_t H, const uint8_t W) { 

  // Matrix index
  const uint16_t x = blockIdx.x*blockDim.x + threadIdx.x;
  const uint16_t y = blockIdx.y*blockDim.y + threadIdx.y;

  src += blockIdx.z * h * w;
  dst += blockIdx.z * H * W;

  uint8_t scale = H / h;

  if (y >= W || x >= H)
    return;

  uint8_t sy = y / scale;
  uint8_t sx = x / scale;

  if (sy == w) --sy;
  if (sx == h) --sx;

  dst[y * H + x] = src[sy * h + sx];
}

mat downsample(const mat& x, size_t scale, SIZE size) {
  int batch_size = x.getCols();

  SIZE output_size = size / scale;

  if ( x.getRows() != size.m * size.n )
    throw runtime_error(RED_ERROR + DEBUG_STR(x.getRows()) + DEBUG_STR(size.m) + DEBUG_STR(size.n));

  mat output(output_size.area(), batch_size);

  ALLOCATE_GRIDS_AND_THREADS(output_size.m, output_size.n);
  grids.z = batch_size;

  downsample_kernel<<<grids, threads>>>(
      output.getData(),
      x.getData(),
      scale, output_size.m, output_size.n);

  CCE(cudaDeviceSynchronize());

  return output;
}

mat upsample(const mat& x, SIZE s, SIZE img) {

  int batch_size = x.getCols();
  int H = s.m, 
      W = s.n,
      h = img.m,
      w = img.n;

  if ( x.getRows() != img.m * img.n )
    throw runtime_error(RED_ERROR + DEBUG_STR(x.getRows()) + DEBUG_STR(img.m) + DEBUG_STR(img.n));

  mat output(H * W, batch_size);
  ALLOCATE_GRIDS_AND_THREADS(H, W);
  grids.z = batch_size;

  upsample_kernel<<<grids, threads>>>(
      output.getData(),
      x.getData(),
      h, w, H, W);

  CCE(cudaDeviceSynchronize());

  return output;
}

/*!
 * Implementation of ConvolutionalLayer goes here. (GPU part only)
 *
 * */
void ConvolutionalLayer::update_bias(const mat& delta) {

  vector<mat> deltas = versplit(delta, getNumOutputMaps(), get_output_img_size().area());
  for (size_t j=0; j<getNumOutputMaps(); ++j) 
    _bias[j] -= sum_all(deltas[j]);
}

void ConvolutionalLayer::update_kernel(const mat& fin, const mat& delta) {

  size_t batch_size = fin.getCols();

  size_t nInputs = getNumInputMaps();
  size_t nOutputs = getNumOutputMaps();

  SIZE kernel = this->get_kernel_size();
  SIZE img_in = this->get_input_img_size();
  SIZE img_out = this->get_output_img_size();

  // Update kernels with learning rate
  vector<mat> Z(nInputs, mat(kernel.area(), nOutputs, 0));

  ALLOCATE_GRIDS_AND_THREADS(kernel.n, kernel.m);
  grids.z = nOutputs;

  size_t SHM_SIZE = getSuitableShmConfig(grids, threads, img_out.m, img_out.n);
  // printf("grids = (%lu, %lu, %lu), threads = (%lu, %lu, %lu) \n", grids.x, grids.y, grids.z, threads.x, threads.y, threads.z);

  for (size_t i=0; i<nInputs; ++i) {
    for (size_t b=0; b<batch_size; ++b) {

      convn_valid_kernel_with_shm<true, false><<< grids, threads, SHM_SIZE, 0 >>>(
	  Z[i].getData(), kernel.m, kernel.n,
	  fin.getData() + i * img_in.area() + b * fin.getRows(), img_in.m, img_in.n,
	  delta.getData() + b * delta.getRows(), img_out.m, img_out.n,
	  kernel.area(), 0, img_out.area());

    }
  }

  CCE(cudaPeekAtLastError());
  for (size_t i=0; i<nInputs; ++i)
    _kernels[i] -= reshapeVectors2Images(Z[i], this->get_kernel_size());
}

/*!
 * Implementation of ConvolutionalLayer goes here. (GPU part only)
 *
 * */
void ConvolutionalLayer::feedForward(mat& fout, const mat& fin) {

  size_t nInputs  = getNumInputMaps(),
	 nOutputs = getNumOutputMaps();

  size_t batch_size = fin.getCols();

  SIZE kernel = this->get_kernel_size();
  SIZE img_in = this->get_input_img_size();
  SIZE img_out = this->get_output_img_size();

  // Map _bias[i] to bias, and then to fout
  //                  ______________________
  //                / %           %% ... %
  //               /  %           %% ... %
  //              /   %           %% ... %  1st feature map
  //             /    %           %% ... %
  //            /     %           %% ... %
  //           /      ______________________
  //          /       #           ## ... #
  //         %        #           ## ... #
  // _bias = # -----  # => fout = ## ... #  2nd feature map
  //         @        #           ## ... #
  //          \       #           ## ... #
  //           \      ______________________
  //            \     @           @@ ... @
  //             \    @           @@ ... @
  //              \   @           @@ ... @  3rd feature map
  //               \  @           @@ ... @
  //                \ @           @@ ... @
  //                  ______________________
  //
  hmat bias(img_out.area() * nOutputs + 1, 1);
  for (size_t j=0; j<nOutputs; ++j) {
    for (size_t a=0; a<img_out.area(); ++a)
      bias[j*img_out.area() + a] = _bias[j];
  }

  fout = mat(bias) * mat(1, batch_size, 1.0f);

  ALLOCATE_GRIDS_AND_THREADS(img_out.n, img_out.m);
  grids.z = batch_size;

  size_t SHM_SIZE = getSuitableShmConfig(grids, threads, kernel.m, kernel.n);

  for (size_t j=0; j<nOutputs; ++j) {
    for (size_t i=0; i<nInputs; ++i) {
      convn_valid_kernel_with_shm<false, false><<< grids, threads, SHM_SIZE, 0 >>>(
	  fout.getData() + j * img_out.area(), img_out.m, img_out.n,
	  fin.getData()  + i * img_in.area(),  img_in.m,  img_in.n,
	  _kernels[i][j].getData(), kernel.m, kernel.n,
	  fout.getRows(), fin.getRows(), 0);
    }
  }

  CCE(cudaPeekAtLastError());
}

void ConvolutionalLayer::feedBackward(mat& error, const mat& delta) {

  size_t nInputs = getNumInputMaps(),
	 nOutputs = getNumOutputMaps();

  size_t batch_size = delta.getCols();

  SIZE kernel = this->get_kernel_size();
  SIZE img_in = this->get_input_img_size();
  SIZE img_out = this->get_output_img_size();

  error.resize(img_in.area() * nInputs + 1, batch_size, 0.);

  ALLOCATE_GRIDS_AND_THREADS(img_in.n, img_in.m);
  grids.z = batch_size;

  size_t SHM_SIZE = getSuitableShmConfig(grids, threads, kernel.m, kernel.n);

  for (size_t i=0; i<nInputs; ++i) {
    for (size_t j=0; j<nOutputs; ++j) {
      convn_full_kernel_with_shm<false, true><<< grids, threads, SHM_SIZE, 0 >>>(
	  error.getData() + i * img_in.area(),  img_in.m,  img_in.n,
	  delta.getData() + j * img_out.area(), img_out.m, img_out.n,
	  _kernels[i][j].getData(), kernel.m, kernel.n,
	  error.getRows(), delta.getRows(), 0);
    }
  }
}

/*!
 * Implementation of SubSamplingLayer goes here. (GPU part only)
 *
 * */
void SubSamplingLayer::feedForward(mat& fout, const mat& fin) {

  SIZE img_in = this->get_input_img_size();
  SIZE img_out = this->get_output_img_size();

  ALLOCATE_GRIDS_AND_THREADS(img_out.m, img_out.n);
  grids.z = getNumOutputMaps();

  fout.resize(img_out.area() * getNumOutputMaps() + 1, fin.getCols());
  
  for (size_t i=0; i<fin.getCols(); ++i) {
    downsample_kernel<<<grids, threads>>>(
	fout.getData() + i * fout.getRows(),
	fin.getData() + i * fin.getRows(),
	_scale, img_in.m, img_in.n);
  }
  CCE(cudaDeviceSynchronize());
}

void SubSamplingLayer::feedBackward(mat& error, const mat& delta) {
  
  assert(&delta != &error);

  SIZE img_in = this->get_input_img_size();
  SIZE img_out = this->get_output_img_size();

  ALLOCATE_GRIDS_AND_THREADS(img_in.m, img_in.n);
  grids.z = getNumInputMaps();

  error.resize(img_in.area() * getNumInputMaps() + 1, delta.getCols());

  for (size_t i=0; i<delta.getCols(); ++i) {
    upsample_kernel<<<grids, threads>>>(
	error.getData() + i * error.getRows(),
	delta.getData() + i * delta.getRows(),
	img_out.m, img_out.n, img_in.m, img_in.n);
  }

  error *= 1.0f / (_scale * _scale);

  CCE(cudaDeviceSynchronize());
}

