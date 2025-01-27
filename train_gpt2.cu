/*
GPT-2 Transformer Neural Net trained in raw CUDA
GPT-2 Transformer Neural Net trained in raw CUDA
Non-trivial notes to be aware of:

We are being clever in the backward pass to conserve memory.
In particular, all parameters use a += in the backward pass, so we
can later do gradient accumulation. But all activations have = instead of +=
because these are faster (just read, no write). This is okay for all activations
except for those in the residual stream, where the gradients have to add. We make
sure that those parts work out ok and that we do a += as necessary. E.g.,
the layernorms are connected to the residuals so we += in layernorm backward.

In this file we are using Mixed Precision training, so different activations,
parameters, grads and buffers may be kept at different precisions, to take
advantage of the fast low-precision hardware in the latest GPUs (bf16/fp16),
and fp8 (coming soon^TM).

Compile:
make train_gpt2cu

Example launch using bfloat16 on 1 GPU batch size 8, sample/eval every 200 steps:
Also we're using TinyStories here for example as it is a bigger dataset
./train_gpt2cu -b 8 -v 200 -s 200 -i data/TinyStories

Example launch using bfloat16 on 4 GPUs, same as above:
mpirun -np 4 ./train_gpt2cu -b 8 -v 200 -s 200 -i data/TinyStories

If you'd like to see train_gpt2.cu produce identical results to
`python train_gpt2.py`, you can run it like this:
make train_gpt2cu && ./train_gpt2cu -b 4 -t 64 -l 1e-4 -v 200 -s 200 -a 1 -x 10 -f 0
make train_gpt2cu PRECISION=FP32 && ./train_gpt2cu -b 4 -t 64 -l 1e-4 -v 200 -s 200 -a 1 -x 10 -f 0
This reads & runs in fp32, B=4, T=64, LR=1e-4, val/sample never (200),
-a 1 is "overfit single batch", -x 10 is 10 iterations, and -f 0 disables tf32
*/

#include <unistd.h>
#include <stdio.h>
#include <stdarg.h>
#include <string>
// GPU / CUDA related
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cublasLt.h>
#include <nvtx3/nvToolsExt.h>
#include <cuda_profiler_api.h>
// Multi-GPU related
#ifdef MULTI_GPU
#include <mpi.h>
#include <nccl.h>
#endif
// our own utilities
// defines: fopenCheck, freadCheck, fcloseCheck, fseekCheck, mallocCheck
#include "utils.h"
// defines: tokenizer_init, tokenizer_decode, tokenizer_free
#include "tokenizer.h"

// ----------------------------------------------------------------------------
// CUDA precision settings

enum PrecisionMode {
    PRECISION_FP32,
    PRECISION_FP16,
    PRECISION_BF16
};

// Specific configurations based on the enabled precision
#if defined(ENABLE_FP32)
typedef float floatX;
#define CUBLAS_LOWP CUDA_R_32F
#define PRECISION_MODE PRECISION_FP32
const char* load_filename = "gpt2_124M.bin";
#ifdef MULTI_GPU
const ncclDataType_t ncclFloatX = ncclFloat;
#endif

// use fp16 (note: this may require gradient scaler, currently not implemented!)
#elif defined(ENABLE_FP16)
typedef half floatX;
#define CUBLAS_LOWP CUDA_R_16F
#define PRECISION_MODE PRECISION_FP16
const char* load_filename = "gpt2_124M.bin";
#ifdef MULTI_GPU
const ncclDataType_t ncclFloatX = ncclHalf;
#endif

#else // Default to bfloat16
typedef __nv_bfloat16 floatX;
#define CUBLAS_LOWP CUDA_R_16BF
#define PRECISION_MODE PRECISION_BF16
const char* load_filename = "gpt2_124M_bf16.bin"; // bf16 weights specific filename
#ifdef MULTI_GPU
const ncclDataType_t ncclFloatX = ncclBfloat16;
#endif
#endif

// ----------------------------------------------------------------------------
// CUDA utils

// Profiler utils
class NvtxRange {
 public:
    NvtxRange(const char* s) { nvtxRangePush(s); }
    NvtxRange(const std::string& base_str, int number) {
        std::string range_string = base_str + " " + std::to_string(number);
        nvtxRangePush(range_string.c_str());
    }
    ~NvtxRange() { nvtxRangePop(); }
};
#define NVTX_RANGE_FN() NvtxRange nvtx_range(__FUNCTION__)

// try to make sure that 2 blocks fit on A100/H100 to maximise latency tolerance
// this needs to be defines rather than queried to be used for __launch_bounds__
#if __CUDA_ARCH__ == 800 || __CUDA_ARCH__ >= 900
#define MAX_1024_THREADS_BLOCKS 2
#else
#define MAX_1024_THREADS_BLOCKS 1
#endif

// cuBLAS workspace. Hardcoding to 32MiB but only Hopper needs 32, for others 4 is OK
const size_t cublaslt_workspace_size = 32 * 1024 * 1024;
void* cublaslt_workspace = NULL;
cublasComputeType_t cublas_compute = CUBLAS_COMPUTE_32F;
cublasLtHandle_t cublaslt_handle;
cublasHandle_t cublas_handle;
cudaDeviceProp deviceProp;

// CUDA streams & events (note: non-timing events, use separate events for timing/profiling!)
constexpr int num_parallel_streams = 2; // + 1 primary "main_stream" (+ default stream)
cudaStream_t parallel_streams[num_parallel_streams];
cudaEvent_t parallel_events[num_parallel_streams];
cudaStream_t main_stream;
cudaEvent_t main_event;
cudaEvent_t loss_event; // to make sure fused_classifier has written the losses to the CPU buffer

// convenience macro for calculating grid/block dimensions for kernels
#define CEIL_DIV(M, N) (((M) + (N)-1) / (N))

// CUDA error checking
void cudaCheck(cudaError_t error, const char *file, int line) {
  if (error != cudaSuccess) {
    printf("[CUDA ERROR] at file %s:%d:\n%s\n", file, line, cudaGetErrorString(error));
    exit(EXIT_FAILURE);
  }
};
#define cudaCheck(err) (cudaCheck(err, __FILE__, __LINE__))

// cuBLAS error checking
void cublasCheck(cublasStatus_t status, const char *file, int line)
{
    if (status != CUBLAS_STATUS_SUCCESS) {
        printf("[cuBLAS ERROR]: %d %s %d\n", status, file, line);
        exit(EXIT_FAILURE);
    }
}
#define cublasCheck(status) { cublasCheck((status), __FILE__, __LINE__); }

#ifdef MULTI_GPU
void nccl_check(ncclResult_t status, const char *file, int line) {
    if (status != ncclSuccess) {
        printf("[NCCL ERROR] at file %s:%d:\n%s\n", file, line, ncclGetErrorString(status));
        exit(EXIT_FAILURE);
    }
}
#define ncclCheck(err) (nccl_check(err, __FILE__, __LINE__))

void mpi_check(int status, const char *file, int line) {
    if (status != MPI_SUCCESS) {
        char mpi_error[4096];
        int mpi_error_len = 0;
        assert(MPI_Error_string(status, &mpi_error[0], &mpi_error_len) == MPI_SUCCESS);
        printf("[MPI ERROR] at file %s:%d:\n%.*s\n", file, line, mpi_error_len, mpi_error);
        exit(EXIT_FAILURE);
    }
}
#define mpiCheck(err) (mpi_check(err, __FILE__, __LINE__))
#endif

// older nvcc does not provide __ldcs and __stcs for bfloat16, despite these actually just being unsigned shorts.
// we need to be careful here to only define our own versions if none already exist, otherwise the compiler will
// complain.
// If not, you easily get "no viable overload" (for sm52) and "function already exists" (sm_80)
#if defined(ENABLE_BF16) && (__CUDACC_VER_MAJOR__ < 12) && !((__CUDA_ARCH__ >= 800) || !defined(__CUDA_ARCH__))
__device__ floatX __ldcs(const floatX* address) {
    unsigned short bf = __ldcs(reinterpret_cast<const unsigned short*>(address));
    return __nv_bfloat16_raw{bf};
}

__device__ void __stcs(floatX* address, floatX value) {
    __stcs(reinterpret_cast<unsigned short*>(address), ((__nv_bfloat16_raw)value).x);
}
#endif

// warp-level reduction for summing values
__device__ float warpReduceSum(float val) {
    for (int offset = 16; offset > 0; offset /= 2) {
        val += __shfl_xor_sync(0xFFFFFFFF, val, offset);
    }
    return val;
}
// warp-level reduction for finding the maximum value
__device__ float warpReduceMax(float val) {
    for (int offset = 16; offset > 0; offset /= 2) {
        val = fmaxf(val, __shfl_xor_sync(0xFFFFFFFF, val, offset));
    }
    return val;
}
// requires all 32 threads in the warp to be active, but should work for any block size
// uses non-dynamic shared memory so every call increases shared memory requirements by 128 bytes
// the fact it's unique shared memory allows us to avoid an extra __syncthreads() call at the end
// but if called inside a loop, the shared memory will be implicitly reused, so set final_sync to 1
using reduction_func_t = float (*) (float);
template<reduction_func_t warp_reduction>
__device__ float blockReduce(float val, bool final_sync=false, float out_of_bounds=0.0f) {
    // two reductions of up to 1024 threads:
    // 1) inside warp (shuffle), 2) cross-warp (shared memory), 3) inside warp (shuffle)
    __shared__ float shared_val[32];
    const int lane_id = threadIdx.x % 32;
    const int warp_id = threadIdx.x / 32;
    const int num_warps = blockDim.x / 32;

    float warp_val = warp_reduction(val);
    if (lane_id == 0) { shared_val[warp_id] = warp_val; }
    __syncthreads();
    warp_val = (lane_id < num_warps) ? shared_val[lane_id] : out_of_bounds;
    float block_val = warp_reduction(warp_val);

    if (final_sync) {
        __syncthreads(); // only needed in loops when effectively reusing shared memory etc.
    }
    return block_val;
}

// ----------------------------------------------------------------------------
// Packed128 data structure, which forces the compiler to use 128-bit loads/stores
// in GPUs that support (the LDG.128 and STS.128 instructions)
// This is a bit similar to the use of float4 in the case of 32-bit floats, but
// supports arbitrary precision.

template<class ElementType>
struct alignas(16) Packed128 {
    Packed128() = default;
    __device__ explicit Packed128(int4 bits) {
        static_assert(sizeof(bits) == sizeof(payload), "Size mismatch.");
        memcpy(&payload, &bits, sizeof(bits));
    }
    __device__ ElementType& operator[](int index) {
        return payload[index];
    }
    __device__ const ElementType& operator[](int index) const {
        return payload[index];
    }
    __device__ int4 get_bits() const {
        int4 bits;
        static_assert(sizeof(bits) == sizeof(payload), "Size mismatch.");
        memcpy(&bits, &payload, sizeof(bits));
        return bits;
    }
    static constexpr const size_t size = sizeof(int4) / sizeof(ElementType);
    ElementType payload[size];
};

// load a Packed128 from an aligned memory address
template<class ElementType>
__device__ Packed128<ElementType> load128(const ElementType* address) {
    return Packed128<ElementType>{*reinterpret_cast<const int4*>(address)};
}
// load a Packed128 from an aligned memory address with streaming cache hint
template<class ElementType>
__device__ Packed128<ElementType> load128cs(const ElementType* address) {
    return Packed128<ElementType>{__ldcs(reinterpret_cast<const int4*>(address))};
}
// store a Packed128 to an aligned memory address
template<class ElementType>
__device__ void store128(ElementType* target, Packed128<ElementType> value) {
    *reinterpret_cast<int4*>(target) = value.get_bits();
}
// store a Packed128 to an aligned memory address with streaming cache hint
template<class ElementType>
__device__ void store128cs(ElementType* target, Packed128<ElementType> value) {
    __stcs(reinterpret_cast<int4*>(target), value.get_bits());
}
// store a Packed128 to an aligned memory address while caching in L2 but bypassing L1
template<class ElementType>
__device__ void store128cg(ElementType* target, Packed128<ElementType> value) {
    __stcg(reinterpret_cast<int4*>(target), value.get_bits());
}

// short-form typedefs
typedef Packed128<float> f128;
typedef Packed128<floatX> x128;

// ----------------------------------------------------------------------------
// Random Number Generatiom

// Simple xorshift RNG
__device__ __host__ unsigned int random_u32(unsigned long long *state) {
    // xorshift rng: https://en.wikipedia.org/wiki/Xorshift#xorshift.2A
    *state ^= *state >> 12;
    *state ^= *state << 25;
    *state ^= *state >> 27;
    return (*state * 0x2545F4914F6CDD1Dull) >> 32;
}
__device__ __host__ float random_f32(unsigned long long *state) { // random float32 in [0,1)
    return (random_u32(state) >> 8) / 16777216.0f;
}

// SquirrelNoise5 - Squirrel's Raw Noise utilities (version 5)
// This gives us a random number from threadIdx/blockIdx + a single seed for the entire GPU
// todo - possibly overkill and we don't need such high quality random numbers? (tbd)
// http://eiserloh.net/noise/SquirrelNoise5.hpp
__device__ __host__ constexpr unsigned int SquirrelNoise5(int positionX, unsigned int seed)
{
	constexpr unsigned int SQ5_BIT_NOISE1 = 0xd2a80a3f;	// 11010010101010000000101000111111
	constexpr unsigned int SQ5_BIT_NOISE2 = 0xa884f197;	// 10101000100001001111000110010111
	constexpr unsigned int SQ5_BIT_NOISE3 = 0x6C736F4B; // 01101100011100110110111101001011
	constexpr unsigned int SQ5_BIT_NOISE4 = 0xB79F3ABB;	// 10110111100111110011101010111011
	constexpr unsigned int SQ5_BIT_NOISE5 = 0x1b56c4f5;	// 00011011010101101100010011110101
	unsigned int mangledBits = (unsigned int) positionX;
	mangledBits *= SQ5_BIT_NOISE1;
	mangledBits += seed;
	mangledBits ^= (mangledBits >> 9);
	mangledBits += SQ5_BIT_NOISE2;
	mangledBits ^= (mangledBits >> 11);
	mangledBits *= SQ5_BIT_NOISE3;
	mangledBits ^= (mangledBits >> 13);
	mangledBits += SQ5_BIT_NOISE4;
	mangledBits ^= (mangledBits >> 15);
	mangledBits *= SQ5_BIT_NOISE5;
	mangledBits ^= (mangledBits >> 17);
	return mangledBits;
}
__device__ __host__ constexpr unsigned int Get2dNoiseUint(int indexX, int indexY, unsigned int seed)
{
	constexpr int PRIME_NUMBER = 198491317; // Large prime number with non-boring bits
	return SquirrelNoise5(indexX + (PRIME_NUMBER * indexY), seed);
}

// stochastic rounding built on top of Squirel Noise above (with seed updated per step via xorshift)
__device__ __forceinline__ void stochastic_rounding(float in, __nv_bfloat16 *out, unsigned int seed) {
    // todo - is this stochastic rounding *too good*? can we cut any corners?
    unsigned int random = Get2dNoiseUint(threadIdx.x, blockIdx.x, seed);
    unsigned int threshold = random & 0xFFFF;
    unsigned int float_bits = __float_as_uint(in);
    unsigned int rounded_bits = float_bits & 0x0000FFFF;
    float_bits = (rounded_bits > threshold) ? (float_bits | 0xFFFF) : (float_bits  & ~0xFFFF);
    *out = __float2bfloat16_rn(__uint_as_float(float_bits));
}
__device__ __forceinline__ void stochastic_rounding(float in, half *out, unsigned int random) {
    *out = (float)in; // todo - implement this...
}
__device__ __forceinline__ void stochastic_rounding(float in, float *out, unsigned int random) {
    *out = in; // dummy function for when floatX is float (FP32 mode)
}

// ----------------------------------------------------------------------------
// MPI / multi-processing setup

// Parameters specific to training on multiple GPUs.
typedef struct {
    int process_rank;      // Rank of this process among all MPI processes. 0 if no multi-GPU.
    int num_processes;     // Total number of processes. 1 if no multi-GPU.
    int local_device_idx;  // This process GPU index on current machine. 0 if no multi-GPU.
#ifdef MULTI_GPU
    ncclComm_t nccl_comm;  // NCCL communication primitive, used for collective multi-GPU work.
#endif
} MultiGpuConfig;

// one global variable to hold the multi-GPU configuration for this process
MultiGpuConfig multi_gpu_config;

#ifdef MULTI_GPU
// Determine which GPU this process should use.
// Processes on the same machines use different GPU indicies. Processes on other machines don't.
// Copied from NCCL examples: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/examples.html#example-2-one-device-per-process-or-thread
int multi_gpu_get_local_device_idx(int process_rank, int num_processes) {
  char hostname[1024];
  hostname[1023] = '\0';
  // All processes on the same machine will share the same hostname.
  gethostname(hostname, 1023);
  for (int i=0; i < 1024; i++) {
    if (hostname[i] == '.') {
        hostname[i] = '\0';
        break;
    }
  }
  uint64_t hostname_hash = 5381;
  for (int c = 0; hostname[c] != '\0'; c++){ hostname_hash = ((hostname_hash << 5) + hostname_hash) ^ hostname[c]; }

  // Distribute all hostname hashes to all processes.
  uint64_t* all_hostsname_hashes = (uint64_t*)malloc(num_processes * sizeof(uint64_t));
  all_hostsname_hashes[process_rank] = hostname_hash;
  mpiCheck(MPI_Allgather(MPI_IN_PLACE, 0, MPI_DATATYPE_NULL, all_hostsname_hashes, sizeof(uint64_t), MPI_BYTE, MPI_COMM_WORLD));

  // Identify which GPU we need to use.
  int local_device_idx = 0;
  for (int current_process = 0; current_process < num_processes; ++current_process) {
     if (current_process == process_rank) {
      // Found my gpu, local_device_idx now has my target GPU index.
      break;
     }
     if (all_hostsname_hashes[current_process] == all_hostsname_hashes[process_rank]) {
      // This process ID runs on the same machine, but it's not me, skip this GPU
      local_device_idx++;
     }
  }

  free(all_hostsname_hashes);
  return local_device_idx;
}
#endif

MultiGpuConfig multi_gpu_config_init(int *argc, char ***argv) {
#ifdef MULTI_GPU
    // Initialize MPI.
    MultiGpuConfig result;
    mpiCheck(MPI_Init(argc, argv));
    mpiCheck(MPI_Comm_rank(MPI_COMM_WORLD, &result.process_rank));
    mpiCheck(MPI_Comm_size(MPI_COMM_WORLD, &result.num_processes));
    result.local_device_idx = multi_gpu_get_local_device_idx(result.process_rank, result.num_processes);
    cudaCheck(cudaSetDevice(result.local_device_idx));
    ncclUniqueId nccl_id;
    if (result.process_rank == 0) {
        ncclCheck(ncclGetUniqueId(&nccl_id));
    }
    mpiCheck(MPI_Bcast((void *)&nccl_id, sizeof(nccl_id), MPI_BYTE, 0, MPI_COMM_WORLD));
    ncclCheck(ncclCommInitRank(&result.nccl_comm, result.num_processes, nccl_id, result.process_rank));
    return result;
#else
    printf("Multi-GPU support is disabled. Using a single GPU.\n");
    cudaCheck(cudaSetDevice(0));
    MultiGpuConfig result;
    result.process_rank = 0;
    result.num_processes = 1;
    result.local_device_idx = 0;
    return result;
#endif
}

void multi_gpu_config_free(const MultiGpuConfig* multi_gpu_config) {
#ifdef MULTI_GPU
    ncclCheck(ncclCommDestroy(multi_gpu_config->nccl_comm));
    mpiCheck(MPI_Finalize());
#endif
}

// convenience function that only prints if the rank of process is zero
void printf0(const char *format, ...) {
    if (multi_gpu_config.process_rank == 0) {
        va_list args;
        va_start(args, format);
        vprintf(format, args);
        va_end(args);
    }
}

// ----------------------------------------------------------------------------
// cuDNN path
#ifdef ENABLE_CUDNN
// functions defined in cudnn_att.cu
void create_cudnn();
void destroy_cudnn();
void attention_forward_cudnn(floatX* out,  // output: (B, T, NH, HS)
                             float* stats, // output for backward pass: (B, NH, T)
                             floatX* inp,  // input: (B, T, 3, NH, HS) QKV
                             int B, int T, int NH, int C);

void attention_backward_cudnn(floatX* dqkvr,                                       // output
                              floatX* dout, floatX* qkvr, floatX* o, float* stats, // inputs
                              int B, int T, int NH, int C);
#else
void create_cudnn() {}
void destroy_cudnn() {}
#endif // ENABLE_CUDNN

// ----------------------------------------------------------------------------
// all the kernels

__global__ void encoder_forward_kernel3(floatX* out,
                               const int* inp, const floatX* wte, const floatX* wpe,
                               int B, int T, int C) {
    int idx = (blockIdx.x * blockDim.x + threadIdx.x) * x128::size;
    int N = B * T * C;
    if (idx >= N) { return; }

    int bt = idx / C;
    int b = bt / T;
    int t = bt % T;
    int c = idx % C;

    int ix = inp[b * T + t];

    floatX* out_btc = out + b * T * C + t * C + c;
    const floatX* wte_ix = wte + ix * C + c;
    const floatX* wpe_tc = wpe + t * C + c;

    x128 packed_out;
    x128 wte128 = load128cs(wte_ix);
    x128 wpe128 = load128cs(wpe_tc);
    for (int k = 0; k < x128::size; k++) {
        packed_out[k] = (floatX)((float)wte128[k] + (float)wpe128[k]);
    }
    store128(out_btc, packed_out);
}

template <typename T>
__device__ void atomicStochasticAdd(T* address, float val0, float val1, unsigned int seed) {
    static_assert(sizeof(T) == 2, "Only 16-bit atomicStochasticAdd supported.");
    float2 val = make_float2(val0, val1);
    unsigned int* address_as_uint = (unsigned int*)address;
    unsigned int old = *address_as_uint, assumed;
    unsigned int random = Get2dNoiseUint(threadIdx.x, blockIdx.x, seed);
    do {
        assumed = old;
        float2 new_fp32 = make_float2((float)(reinterpret_cast<T*>(&old)[0]) + val.x,
                                      (float)(reinterpret_cast<T*>(&old)[1]) + val.y);
        T new_rounded[2];
        stochastic_rounding(new_fp32.x, &new_rounded[0], random);
        stochastic_rounding(new_fp32.y, &new_rounded[1], random >> 16);
        old = atomicCAS(address_as_uint, assumed, *(unsigned int*)&new_rounded);
    } while (assumed != old);
}
__device__ void atomicStochasticAdd(float* address, float val0, float val1, unsigned int seed) {
    atomicAdd(address, val0);
    atomicAdd(address + 1, val1);
}

__global__ void encoder_backward_kernel(floatX* dwte, floatX* dwpe,
                                        const floatX* dout, const int* inp,
                                        int B, int T, int C, unsigned int seed) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int N = B * T * C;
    idx *= 2; // 2 elements per thread
    if (idx >= N) { return; }

    int bt = idx / C;
    int b = bt / T;
    int t = bt % T;
    int c = idx % C;

    int ix = inp[b * T + t];

    const floatX* dout_btc = dout + b * T * C + t * C + c;
    floatX* dwte_ix = dwte + ix * C + c;
    floatX* dwpe_tc = dwpe + t * C + c;

    float2 dout_data = make_float2(dout_btc[0], dout_btc[1]);
    atomicStochasticAdd(dwte_ix, dout_data.x, dout_data.y, seed);
    atomicStochasticAdd(dwpe_tc, dout_data.x, dout_data.y, seed ^ 0xFFFFFFFF);
}

__global__ void layernorm_forward_kernel3(floatX* __restrict__ out, floatX* __restrict__ mean, floatX* __restrict__ rstd,
                                    const floatX*  __restrict__ inp, const floatX*  __restrict__ weight,
                                    const floatX* __restrict__ bias, int N, int C) {
    const int warp_size = 32;
    int lane_id = threadIdx.x % warp_size;
    int warp_id = threadIdx.x / warp_size;
    int num_warps = blockDim.x / warp_size;

    int idx = blockIdx.x * num_warps + warp_id;
    if(idx >= N) { return; } // guard

    // the row of input that this group of threads is responsible for
    const floatX* x = inp + idx * C;

    // mean
    float sum = 0.0f;
    for (int i = lane_id; i < C; i += warp_size) {
        sum += (float)x[i];
    }
    sum = warpReduceSum(sum);
    float m = sum / C;
    if(lane_id == 0 && mean != nullptr) {
        __stcs(mean + idx, (floatX)m);
    }

    // rstd
    sum = 0.0f;
    for (int i = lane_id; i < C; i += warp_size) {
        float diff = (float)x[i] - m;
        sum += diff * diff;
    }
    sum = warpReduceSum(sum);
    float s = rsqrtf(sum / C + 1e-5f);
    if(lane_id == 0 && rstd != nullptr) {
        __stcs(rstd + idx, (floatX)s);
    }

    // final normalization and scaling by weight/bias
    floatX* o = out + idx * C;
    for (int c = lane_id; c < C; c += warp_size) {
        // load and store using the .cs "streaming" hint to the compiler,
        // indicating that this data will not be reused soon, and can be streamed through the caches
        // this allows the threads to get more cache-hits for the (shared) weight and bias parameters
        float n = s * ((float)__ldcs(x+c) - m);
        __stcs(o+c, (floatX)(n * (float)weight[c] + (float)bias[c]));
    }
}

// inputs floatX, outputs FP32 (for current FP32-only activation path for this WIP)
__global__ void permute_kernel(floatX* q, floatX* k, floatX* v,
                               const floatX* inp,
                               int B, int N, int NH, int d) {
    // okay so now, this kernel wants Q,K,V to all be of shape (B, NH, N, d)
    // but instead, we have a single tensor QKV (inp) of shape (B, N, 3, NH, d)
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= B * NH * N * d) { return; }

    // Q[b][nh_][n][d_] = inp[b][n][0][nh_][d_]
    int b = idx / (NH * N * d);
    int rest = idx % (NH * N * d);
    int nh_ = rest / (N * d);
    rest = rest % (N * d);
    int n = rest / d;
    int d_ = rest % d;
    int inp_idx = (b * N * 3 * NH * d) + (n * 3 * NH * d) + (0 * NH * d) + (nh_ * d) + d_;
    q[idx] = __ldcs(&inp[inp_idx]);
    k[idx] = __ldcs(&inp[inp_idx + NH * d]);
    v[idx] = __ldcs(&inp[inp_idx + 2 * (NH * d)]);
}

__global__ void permute_kernel_backward(floatX* dinp,
                                        const floatX* dq, const floatX* dk, const floatX* dv,
                                        int B, int N, int NH, int d) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= B * NH * N * d) { return; }

    int b = idx / (NH * N * d);
    int rest = idx % (NH * N * d);
    int nh_ = rest / (N * d);
    rest = rest % (N * d);
    int n = rest / d;
    int d_ = rest % d;

    int inp_idx = (b * N * 3 * NH * d) + (n * 3 * NH * d) + (0 * NH * d) + (nh_ * d) + d_;
    dinp[inp_idx] = dq[idx];
    dinp[inp_idx + NH * d] = dk[idx];
    dinp[inp_idx + 2 * (NH * d)] = dv[idx];
}

__global__ void unpermute_kernel(floatX* inp, floatX *out, int B, int N, int NH, int d) {
   // out has shape (B, nh, N, d) but we need to unpermute it to (B, N, nh, d)

    int idx = (blockIdx.x * blockDim.x + threadIdx.x);
    // out[b][n][nh_][d_] <- inp[b][nh_][n][d_]
    if (idx >= B * NH * N * d) { return; }

    int b = idx / (NH * N * d);
    int rest = idx % (NH * N * d);
    int nh_ = rest / (N * d);
    rest = rest % (N * d);
    int n = rest / d;
    int d_ = rest % d;
    int other_idx = (b * NH * N * d) + (n * NH * d) + (nh_ * d) + d_;
    out[other_idx] = __ldcs(&inp[idx]);
}

__global__ void unpermute_kernel_backward(floatX* dinp, const floatX *dout, int B, int N, int NH, int d) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= B * NH * N * d) { return; }

    int b = idx / (NH * N * d);
    int rest = idx % (NH * N * d);
    int nh_ = rest / (N * d);
    rest = rest % (N * d);
    int n = rest / d;
    int d_ = rest % d;
    int other_idx = (b * NH * N * d) + (n * NH * d) + (nh_ * d) + d_;
    dinp[idx] = (floatX)dout[other_idx];
}

__global__ void softmax_forward_kernel5(floatX* out, float inv_temperature, const floatX* inp, int N, int T) {
    // inp, out shape: (N, T, T), where N = B * NH
    // fuses the multiplication by scale inside attention
    // directly autoregressive, so we only compute the lower triangular part
    // uses the online softmax algorithm
    assert(T % 4  == 0);
    const int warp_size = 32;
    int lane_id = threadIdx.x % warp_size;
    int warp_id = threadIdx.x / warp_size;
    int num_warps = blockDim.x / warp_size;

    // micro-optimization: we iterate backwards so that
    // after the softmax backward operation completes, the cache retains the
    // part of the matrix close to the upper left corner, which benefits the
    // matmul operation that immediately follows.
    // int idx = blockIdx.x * warp.meta_group_size() + warp.meta_group_rank(); // forward order
    int idx = (gridDim.x - blockIdx.x - 1) * num_warps + warp_id; // backward order
    if(idx >= N * T) {
        return;
    }
    int own_pos = idx % T;
    int pos_by_4 = own_pos / 4;

    // one row of inp, i.e. inp[idx, :] of shape (T,)
    const floatX* x = inp + idx * T;

    // not INF, so we don't get NaNs accidentally when subtracting two values.
    const float flt_max = 340282346638528859811704183484516925440.0f; // to avoid including float.h
    float maxval = -flt_max;
    float sumval = 0.0f;

    const floatX* x_aligned = reinterpret_cast<const floatX*>(__builtin_assume_aligned(x, 16));
    for (int i = lane_id; i < pos_by_4; i += warp_size) {
        float regarray[4];
        for (int k = 0; k < 4; ++k) {
            regarray[k] = (float)x_aligned[4*i + k];
        }
        float old_maxval = maxval;
        for(int k = 0; k < 4; ++k) {
            maxval = fmaxf(maxval, regarray[k]);
        }
        sumval *= expf(inv_temperature * (old_maxval - maxval));
        for(int k = 0; k < 4; ++k) {
            sumval += expf(inv_temperature * (regarray[k] - maxval));
        }
    }

    if(4*pos_by_4 + lane_id <= own_pos) {
        float old_maxval = maxval;
        maxval = fmaxf(maxval, (float)x[4*pos_by_4 + lane_id]);
        sumval *= expf(inv_temperature * (old_maxval - maxval));
        sumval += expf(inv_temperature * ((float)x[4*pos_by_4 + lane_id] - maxval));
    }

    float global_maxval = warpReduceMax(maxval);
    sumval *= expf(inv_temperature * (maxval - global_maxval));

    float sum = warpReduceSum(sumval);
    float norm = 1.f / sum;

    // divide the whole row by the sum
    for (int i = lane_id; i <= own_pos; i += warp_size) {
        // recalculation is faster than doing the round-trip through memory.
        float ev = expf(inv_temperature * ((float)__ldcs(x + i) - global_maxval));
        __stcs(out + idx * T + i, (floatX)(ev * norm));
    }
}

__global__ void residual_forward_kernel(floatX* out, floatX* inp1, floatX* inp2, int N) {
    int idx = (blockIdx.x * blockDim.x + threadIdx.x) * x128::size;
    if (idx >= N) { return; }

    x128 packed_out;
    x128 packed_inp1 = load128cs(inp1 + idx);
    x128 packed_inp2 = load128cs(inp2 + idx);
    for (int k = 0; k < packed_inp1.size; k++) {
        packed_out[k] = (floatX)((float)packed_inp1[k] + (float)packed_inp2[k]);
    }
    store128(out + idx, packed_out);
}

#define GELU_SCALING_FACTOR sqrtf(2.0f / M_PI)
__global__ void gelu_forward_kernel2(floatX* out, const floatX* inp, int N) {
    int idx = (blockIdx.x * blockDim.x + threadIdx.x) * x128::size;
    if (idx >= N) { return; }

    x128 packed_out;
    x128 packed_inp = load128cs(inp + idx); // load and do not keep in cache
    for(int k = 0; k < packed_inp.size; ++k) {
        float xi = (float)packed_inp[k];
        float cube = 0.044715f * xi * xi * xi;
        packed_out[k] = (floatX)(0.5f * xi * (1.0f + tanhf(GELU_SCALING_FACTOR * (xi + cube))));
    }
    // store instead of storecs (without cache streaming) in case it is useful for the
    // data to be in the cache for the next operation after this GeLU
    store128(out + idx, packed_out);
}

__global__ void gelu_backward_kernel(floatX* dinp, const floatX* inp, const floatX* dout, const int N) {
    int idx = (blockIdx.x * blockDim.x + threadIdx.x) * x128::size;
    if (idx >= N) { return; }

    x128 packed_dinp;
    x128 packed_inp = load128cs(inp + idx);
    x128 packed_dout = load128cs(dout + idx);
    for (int k = 0; k < packed_inp.size; ++k) {
        float x = (float)packed_inp[k];
        float cube = 0.044715f * x * x * x;
        float tanh_arg = GELU_SCALING_FACTOR * (x + cube);
        float tanh_out = tanhf(tanh_arg);
        float coshf_out = coshf(tanh_arg);
        float sech_out = 1.0f / (coshf_out * coshf_out);
        float local_grad = 0.5f * (1.0f + tanh_out) + x * 0.5f * sech_out * GELU_SCALING_FACTOR * (1.0f + 3.0f * 0.044715f * x * x);
        packed_dinp[k] = (floatX)(local_grad * (float)packed_dout[k]);
    }
    store128(dinp + idx, packed_dinp);
}

__global__ void matmul_backward_bias_kernel7(float* dbias, const floatX* dout, int B, int T, int OC) {
    // note: this kernel reads in floatX, but it writes to float!
    // this is because we're using atomics, which are super slow in < fp32 precision on < H100 GPUs
    // so the trick is do fp32 atomics to a buffer, and then copy_and_cast the result to floatX
    // (this also results in higher accuracy than doing doing accumulation directly in floatX)

    // see comments in matmul_backward() for an explanation of block/grid dimensions etc.
    const int block_size = 512;
    const int block_size_x = 32;
    const int block_size_y = block_size / block_size_x; // 16
    const int OC_per_warp = block_size_x * x128::size;  // 256 at BF16

    int local_oc = threadIdx.x * x128::size;
    int global_oc = blockIdx.x * OC_per_warp + local_oc;
    float accumulators[x128::size];
    __shared__ float shared[OC_per_warp];

    for (int k = 0; k < x128::size; k++) {
        accumulators[k] = 0.0f;
    }
    int thread_id = threadIdx.y * block_size_x + threadIdx.x;
    for (int idx = thread_id; idx < OC_per_warp; idx += block_size) {
        shared[idx] = 0.0f;
    }
    __syncthreads();
    for (int idx = blockIdx.y*block_size_y + threadIdx.y; idx < B * T; idx += gridDim.y*block_size_y) {
        x128 packed_dout = load128(dout + global_oc + idx*OC);
        for (int k = 0; k < x128::size; k++) {
            accumulators[k] += (float)packed_dout[k];
        }
    }
    // we need to avoid shared memory bank conflicts for the atomicAdd to maximise performance
    // so we accumulate in a conflict-free order, then reorder to match the global memory order
    for (int k = 0; k < x128::size; k++) {
        atomicAdd(shared + threadIdx.x + (k * block_size_x), accumulators[k]);
    }
    if (threadIdx.y >= x128::size) { return; } // only need this many warps to reorder the data
    __syncthreads();
    // read the accumulated values in the conflict-free order
    int i = threadIdx.x + (threadIdx.y * block_size_x);
    float tmp = shared[i];
    __syncthreads();
    // write them back to shared memory in the global memory order
    // 8-way bank conflict for BF16 x128, but only 8x per threadblock (rather than 8x per warp)
    shared[local_oc + threadIdx.y] = tmp;
    __syncthreads();
    // now we do a perfectly coalesced atomic add to global memory (1x 128-byte cacheline per warp)
    atomicAdd(dbias + i + blockIdx.x*OC_per_warp, shared[i]);
}

__global__ void __launch_bounds__(512, 3) // todo - any warnings on Turing with only 1024 threads?
                layernorm_backward_kernel8(floatX* dinp, floatX* dweight, floatX* dbias, float* scratch,
                                            const floatX* dout, const floatX* inp, const floatX* weight,
                                            const floatX* mean, const floatX* rstd,
                                            int B, int T, int C) {
    extern __shared__ float shared[]; // size = 2 * C + 1
    int warpId = threadIdx.x / warpSize; // warp index within a block
    int warpsInBlock = blockDim.x / warpSize; //number of warps in block
    int baseIdx = blockIdx.x * warpsInBlock + warpId;
    int warpThreadIdx = threadIdx.x % warpSize; // Thread index within the warp
    int warpsInGrid = gridDim.x * warpsInBlock;
    int C_per_iteration = warpSize * x128::size;
    int iterations_C = C / C_per_iteration;

    // the first half of shared memory is bias, second is weight
    float* dbias_shared = shared;
    float* dweight_shared = shared + C;

    // init shared memory to zero
    for(int i = threadIdx.x; i < C; i+= blockDim.x){
       dbias_shared[i] = 0.0f;
       dweight_shared[i] = 0.0f;
    }
    unsigned int *tmp_flag = (unsigned int*)(shared + C*2);
    __syncthreads();

    for (int idx = baseIdx; idx < B * T; idx += warpsInGrid) {
        int b = idx / T;
        int t = idx % T;

        const floatX* dout_bt = dout + b * T * C + t * C;
        const floatX* inp_bt = inp + b * T * C + t * C;
        floatX* dinp_bt = dinp + b * T * C + t * C;
        const float mean_bt = (float)mean[b * T + t];
        const float rstd_bt = (float)rstd[b * T + t];

        // first: two reduce operations
        float dnorm_mean = 0.0f;
        float dnorm_norm_mean = 0.0f;
        for (int i = warpThreadIdx * x128::size; i < C; i += warpSize * x128::size) {
            x128 dout128_i   = load128(dout_bt + i);
            x128 inp128_i    = load128(inp_bt  + i);
            x128 weight128_i = load128(weight  + i);
            for (int k = 0; k < x128::size; k++) {
                float norm_bti = ((float)inp128_i[k] - mean_bt) * rstd_bt;
                float dnorm_i = (float)weight128_i[k] * (float)dout128_i[k];
                dnorm_mean += dnorm_i;
                dnorm_norm_mean += dnorm_i * norm_bti;
            }
        }
        dnorm_mean = warpReduceSum(dnorm_mean) / C;
        dnorm_norm_mean = warpReduceSum(dnorm_norm_mean) / C;

        // now iterate again and accumulate all the gradients
        // unfortunately we cannot use the same index for x128 arrays and shared memory
        // as atomics can only be 32-bit rather than 128-bit (at least pre-SM90/Hopper)
        // so this would result in an 8-way bank conflict, and kill performance
        // so instead, we use a shared memory friendly index, and reorder before the final write
        for (int i = 0; i < iterations_C; i++) {
            int global_index = (warpThreadIdx * x128::size) + (i * C_per_iteration);
            int shared_index = warpThreadIdx + (i * C_per_iteration);
            x128 dout128   = load128cs(dout_bt + global_index);
            x128 inp128    = load128cs(inp_bt  + global_index);
            x128 dinp128   = load128(dinp_bt   + global_index);
            x128 weight128 = load128(weight    + global_index);

            for (int x = 0; x < x128::size; x++) {
                float dout_i = (float)dout128[x];
                float norm_bti = ((float)inp128[x] - mean_bt) * rstd_bt;
                float dnorm_i = (float)weight128[x] * dout_i;
                // gradient contribution to bias (using shared memory friendly index)
                atomicAdd(&dbias_shared[shared_index + x*warpSize], dout_i);
                // gradient contribution to weight (using shared memory friendly index)
                atomicAdd(&dweight_shared[shared_index + x*warpSize], norm_bti * dout_i);
                // gradient contribution to input
                float dval = 0.0f;
                dval += dnorm_i; // term 1
                dval -= dnorm_mean; // term 2
                dval -= norm_bti * dnorm_norm_mean; // term 3
                dval *= rstd_bt; // final scale
                dinp128[x] = (floatX)((float)dinp128[x] + dval);
            }
            // cache in L2 as this is read by the next kernel, but bypass L1 to minimise thrashing
            store128cg(dinp_bt + global_index, dinp128);
        }
    }
    // Accumulate into a FP32 scratchpad
    // BF16 atomics are potentially much slower... and this is more precise!
    // todo - could potentially avoid the extra copy if floatX is FP32, fairly negligible though
    __syncthreads();
    float* scratch_dbias = scratch;
    float* scratch_dweight = scratch + C;
    unsigned int* scratchFlag = (unsigned int*)(scratch + (2 * C));
    for(int i = threadIdx.x; i < C; i+= blockDim.x) {
        // global atomics in the same "shared memory banking friendly" order
        atomicAdd(&scratch_dbias[i], dbias_shared[i]);
        atomicAdd(&scratch_dweight[i], dweight_shared[i]);
    }
    __syncthreads();
    if (threadIdx.x == 0) {
        *tmp_flag = atomicInc(scratchFlag, gridDim.x);
    }
    __syncthreads();
    if (*tmp_flag == gridDim.x-1) {
        for (int i = warpId; i < iterations_C; i += warpsInBlock) {
            // reorder from atomic/shared memory-friendly index to real global memory index
            // and convert from float/FP32 to floatX/BF16 for the final write
            int global_index = (warpThreadIdx * x128::size) + (i * C_per_iteration);
            int shared_index = warpThreadIdx + (i * C_per_iteration);

            x128 dbias128;
            x128 dweight128;
            for (int x = 0; x < x128::size; x++) {
                dbias128[x] = (floatX)scratch_dbias[shared_index + x*warpSize];
                dweight128[x] = (floatX)scratch_dweight[shared_index + x*warpSize];
            }
            store128(dbias + global_index, dbias128);
            store128(dweight + global_index, dweight128);
        }
    }
}

__global__ void softmax_autoregressive_backward_kernel(floatX* dpreatt, const floatX* datt, const floatX* att,
                                                       int B, int T, int C, float scale) {
    constexpr const int BlockSize = 256;
    constexpr int T_per_block = 4;

    // go through blocks in reverse order, so the slowest block starts first
    int t0 = T - 1 - T_per_block*blockIdx.x;
    int idx = blockIdx.y;

    att += idx * T * T;
    datt += idx * T * T;
    dpreatt += idx * T * T;

    for(int to = 0; to < T_per_block; ++to) {
        int t = t0 - to;
        if(t < 0) return;
        const floatX* att_bth = att + t * T;
        const floatX* datt_bth = datt + t * T;
        floatX* dpreatt_bth = dpreatt + t * T;

        float local_sum = 0;
        for (int t2 = threadIdx.x; t2 <= t; t2 += BlockSize) {
            local_sum += (float)att_bth[t2] * (float)datt_bth[t2];
        }

        local_sum = blockReduce<warpReduceSum>(local_sum);

        for (int t3 = threadIdx.x; t3 <= t; t3 += BlockSize) {
            // don't touch the cache. Some parts will still be here from the previous loop, and
            // we want to exploit those.
            float acc = (float)__ldcs(att_bth + t3) * ((float)__ldcs(datt_bth + t3) - local_sum);
            __stcs(dpreatt_bth + t3, (floatX)(scale * acc));
        }
    }
}

// Implements linear interpolation using only two floating-point operations (as opposed to three in a naive implementation).
// Reference: https://developer.nvidia.com/blog/lerp-faster-cuda
__device__ float lerp(float start, float end, float weight) {
    return fma(weight, end, fma(-weight, start, start));
}

template <typename Tp, typename Tg>
__global__ void adamw_kernel3(Tp* params_memory, float* master_params_memory, Tg* grads_memory, float* m_memory, float* v_memory, size_t num_parameters,
                              float learning_rate, float beta1, float beta2, float beta1_correction, float beta2_correction, float eps, float weight_decay,
                              unsigned int seed) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= num_parameters) { return; }  // guard
    // get the gradient, m, and v for this parameter
    float grad = (float)grads_memory[idx];
    float m = m_memory[idx];
    float v = v_memory[idx];
    // update the first moment (momentum)
    m = lerp(grad, m, beta1);
    m_memory[idx] = m;
    // update the second moment (RMSprop)
    v = lerp(grad * grad, v, beta2);
    v_memory[idx] = v;
    m /= beta1_correction;  // m_hat
    v /= beta2_correction;  // v_hat
    // fetch the old value of this parameter as a float, from either source
    float old_param = (master_params_memory != NULL) ? master_params_memory[idx] : (float)params_memory[idx];
    // update this parameter
    float param = old_param - (learning_rate * (m / (sqrtf(v) + eps) + weight_decay * old_param));
    // update our low precision version of the parameters using stochastic rounding
    // this will be used in the next forward pass
    // TODO: simply doing `params_memory[i] = (floatX)param;` breaks everything (why?)
    unsigned int random = Get2dNoiseUint(threadIdx.x, blockIdx.x, seed);
    stochastic_rounding(param, &params_memory[idx], random);
    // write the full, float version of the param into our master copy, if we maintain one
    // this will be used in the next update
    if (master_params_memory != NULL) { master_params_memory[idx] = param; }
}

struct SoftmaxParams {
    float Scale;
    float Offset;
};

__device__ SoftmaxParams prepare_softmax_blockwide3(int idx, const floatX* inp, int V, int P) {
    // same but not float4
    // one row of inp, i.e. inp[idx, :] of shape (V,)

    const floatX* x = inp + idx * P;
    float thread_maxval = -INFINITY;
    float thread_sumval = 0.0f;
    int i = (V+x128::size-1)/x128::size + threadIdx.x - blockDim.x;

    // special-case loop to handle the unaligned elements at the end of the array
    // this lets us skip the bounds check in the main loop below, which improves performance
    while ((i+1)*x128::size > V) {
        for(int k = 0; k < x128::size; ++k) {
            if (i*x128::size+k >= V) {
                break; // bounds checking against real V (rather than padded P)
            }
            float v = (float)x[i*x128::size+k];
            float old_maxval = thread_maxval;
            thread_maxval = fmaxf(thread_maxval, v);
            thread_sumval *= expf((old_maxval - thread_maxval));
            thread_sumval += expf(v - thread_maxval);
        }
        i -= blockDim.x;
    }

    // main loop for the bulk of the iterations (no bounds checking required!)
    for (; i >= 0; i -= blockDim.x) {
        x128 packed_x = load128(x + i * x128::size); // load and keep in cache until fused_classifier loop
        for(int k = 0; k < x128::size; ++k) {
            float v = (float)packed_x[k];
            float old_maxval = thread_maxval;
            thread_maxval = fmaxf(thread_maxval, v);
            thread_sumval *= expf((old_maxval - thread_maxval));
            thread_sumval += expf(v - thread_maxval);
        }
    }

    // Block Max Reduction -> Maths -> Block Sum Reduction
    float block_maxval = blockReduce<warpReduceMax>(thread_maxval, false, -INFINITY);
    thread_sumval *= expf(thread_maxval - block_maxval);
    float block_sumval = blockReduce<warpReduceSum>(thread_sumval);

    // return the softmax parameters
    return SoftmaxParams{1.f / block_sumval, block_maxval};
}

// will _update_ logits to logit gradients
// uses template to decide whether to write logits and probs
// split both loops in "multiple-of-x128-size" and "bounds-checked remainder" parts
template <bool WriteLogits = true, bool WriteProbs = false>
__global__ void __launch_bounds__(1024, MAX_1024_THREADS_BLOCKS)
                fused_classifier_kernel5(floatX* logits, floatX* losses, floatX* probs,
                                         const floatX* dlosses, const int* targets,
                                         int B, int T, int V, int P) {
    int idx = gridDim.x - (blockIdx.x+1); // reverse order for cache hits on matmul data
    int ix = targets[idx];

    // softmax (reading B * T * V, same logits read again below, hopefully still in cache)
    SoftmaxParams sp = prepare_softmax_blockwide3(idx, logits, V, P);

    // calculate the probability needed for the loss and update (single-threaded)
    if(threadIdx.x == 0) {
        float prob = expf((float)logits[idx * P + ix] - sp.Offset) * sp.Scale;
        losses[idx] = (floatX)(-logf(prob));
    }

    // very sensible default for dlosses is 1/(B*T), which is the uniform loss
    float dloss = (dlosses != NULL) ? (float)dlosses[idx] : 1.0f / (B*T);
    // calculate the gradients directly, saves bandwidth from probs during training
    // but also supports writing probs for inference-only and debugging
    const floatX* logits_vec = logits + idx * P;
    for (int i = threadIdx.x; i < V/x128::size; i += blockDim.x) {
        // this is the 2nd read of logits after the one in prepare_softmax2
        // it will be overwritten by the logits gradients which is when we reduce cache persistence
        x128 packed_logits_vec = load128(logits_vec + i * x128::size); // rely on cs of store128cs
        x128 packed_probs;
        for(int k = 0; k < x128::size; ++k) {
            int element = i*x128::size + k;
            float prob = expf((float)packed_logits_vec[k] - sp.Offset) * sp.Scale;
            packed_probs[k] = (floatX)prob;
            float indicator = (element == ix) ? 1.0f : 0.0f;
            packed_logits_vec[k] = (floatX)((prob - indicator) * dloss);
        }
        if (WriteLogits){
            // reduce cache persistence for the overwritten logits
            // to maximise probability that logits remain in cache between prepare_softmax and here
            store128cs(logits + idx * P + i * x128::size, packed_logits_vec);
        }
        if (WriteProbs) {
            store128(probs + idx * P + i * x128::size, packed_probs);
        }
    }

    // handle remaining elements after the last multiple of x128::size
    // e.g. if V = 8003, and x128::size = 8, we need to handle the last 3 elements
    int unaligned_start = V & ~(x128::size - 1); // round down to multiple of x128::size
    for (int i = threadIdx.x + unaligned_start; i < V; i++) {
        float prob = expf((float)logits_vec[i] - sp.Offset) * sp.Scale;
        float indicator = (i == ix) ? 1.0f : 0.0f;
        float dlogit = (prob - indicator) * dloss;
        if (WriteLogits){
            __stcs(logits + idx * P + i, (floatX)dlogit);
        }
        if (WriteProbs) {
            probs[idx * P + i] = (floatX)prob;
        }
    }
}

__global__ void copy_and_cast_kernel(float* dst, const floatX* src, size_t n) {
    // a small kernel to copy and cast, i.e. `dst <- (float) src`
    const size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) { dst[idx] = (float)src[idx]; }
}

__global__ void cast_and_add_kernel(floatX* dst, const float* src, size_t n) {
    // used only for matmul_backward_bias kernel, a little bit embarassing TODO delete later
    const size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) { dst[idx] = (floatX)((float)dst[idx] + src[idx]); } // have to += because dbias is a paramater
}

// ----------------------------------------------------------------------------
// kernel launchers

void encoder_forward(floatX* out,
                     const int* inp, const floatX* wte, const floatX* wpe,
                     int B, int T, int C) {
    NVTX_RANGE_FN();
    const int block_size = 256;
    const int N = B * T * C;
    const int grid_size = CEIL_DIV(N, (int)(block_size * x128::size));
    encoder_forward_kernel3<<<grid_size, block_size, 0, main_stream>>>(out, inp, wte, wpe, B, T, C);
    cudaCheck(cudaGetLastError());
}

void encoder_backward(floatX* dwte, floatX* dwpe,
                    const floatX* dout, const int* inp,
                    int B, int T, int C, unsigned int seed) {
    NVTX_RANGE_FN();
    const int N = B * T * C;
    const int block_size = 256;
    const int grid_size = CEIL_DIV(N, block_size * 2); // each thread handles 2 elements
    encoder_backward_kernel<<<grid_size, block_size, 0, main_stream>>>(dwte, dwpe, dout, inp, B, T, C, seed);
    cudaCheck(cudaGetLastError());
}

void layernorm_forward(floatX* out, floatX* mean, floatX* rstd,
                       floatX* inp, floatX* weight, floatX* bias,
                       int B, int T, int C) {
    NVTX_RANGE_FN();
    const int block_size = 512;
    const int N = B * T;
    const int grid_size = CEIL_DIV(N * 32, block_size);
    layernorm_forward_kernel3<<<grid_size, block_size, 0, main_stream>>>(out, mean, rstd, inp, weight, bias, N, C);
    cudaCheck(cudaGetLastError());
}

// https://docs.nvidia.com/cuda/cublas/#cublasltmatmul
void matmul_forward_cublaslt(floatX* out,
                     floatX* inp, floatX* weight, floatX* bias,
                     int B, int T, int C, int OC) {
    NVTX_RANGE_FN();
    int has_bias = (bias != NULL);

    // check bias alignment
    if(((uintptr_t)bias % 16) != 0) {
        printf("Bias pointer is not aligned (cuBLASLt requirement)!\n");
        exit(EXIT_FAILURE);
    }

    // these need to be in FP16 if and only if alpha/beta are CUBLAS_COMPUTE_16F
    const float alpha = 1.0f, beta = 0.0f;

    int returnedResults = 0;
    cublasLtMatmulDesc_t operationDesc;
    cublasLtMatmulPreference_t preference;
    cublasLtMatrixLayout_t weightLayout;
    cublasLtMatrixLayout_t inputLayout;
    cublasLtMatrixLayout_t outputLayout;
    cublasLtMatrixLayout_t biasLayout;
    cublasLtMatmulHeuristicResult_t heuristic;

    // create the operation descriptor
    cublasOperation_t opNoTranspose = CUBLAS_OP_N;
    cublasOperation_t opTranspose = CUBLAS_OP_T;
    cublasLtEpilogue_t epilogueBias = has_bias ? CUBLASLT_EPILOGUE_BIAS : CUBLASLT_EPILOGUE_DEFAULT;

    cublasCheck(cublasLtMatmulDescCreate(&operationDesc, cublas_compute, CUDA_R_32F)); // FP16 if CUBLAS_COMPUTE_16F
    cublasCheck(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_TRANSA, &opTranspose, sizeof(opTranspose)));
    cublasCheck(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_TRANSB, &opNoTranspose, sizeof(opNoTranspose)));
    cublasCheck(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_EPILOGUE, &epilogueBias, sizeof(epilogueBias)));
    cublasCheck(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_BIAS_POINTER, &bias, sizeof(bias)));

    // define matrix layouts
    cublasCheck(cublasLtMatrixLayoutCreate(&weightLayout, CUBLAS_LOWP, C, OC, C));
    cublasCheck(cublasLtMatrixLayoutCreate(&inputLayout, CUBLAS_LOWP, C, B*T, C));
    cublasCheck(cublasLtMatrixLayoutCreate(&outputLayout, CUBLAS_LOWP, OC, B*T, OC));
    cublasCheck(cublasLtMatrixLayoutCreate(&biasLayout, CUBLAS_LOWP, OC, 1, OC));

    // create a preference handle with specified max workspace
    cublasCheck(cublasLtMatmulPreferenceCreate(&preference));
    cublasCheck(cublasLtMatmulPreferenceSetAttribute(preference,
        CUBLASLT_MATMUL_PREF_MAX_WORKSPACE_BYTES, &cublaslt_workspace_size, sizeof(cublaslt_workspace_size)));

    // find a suitable algorithm
    cublasCheck(cublasLtMatmulAlgoGetHeuristic(cublaslt_handle, operationDesc,
        weightLayout, inputLayout, outputLayout, outputLayout,
        preference, 1, &heuristic, &returnedResults));
    if (returnedResults == 0) {
        printf("No cuBLASLt algorithm: B: %d, T: %d, C: %d, OC: %d, bias: %d\n", B, T, C, OC, has_bias);
        exit(EXIT_FAILURE);
    }

    // call the matmul
    cublasCheck(cublasLtMatmul(cublaslt_handle, operationDesc,
        &alpha, weight, weightLayout, inp, inputLayout, &beta,
        out, outputLayout, out, outputLayout, &heuristic.algo,
        cublaslt_workspace, cublaslt_workspace_size, main_stream));

    // cleanups
    cublasCheck(cublasLtMatmulPreferenceDestroy(preference));
    cublasCheck(cublasLtMatmulDescDestroy(operationDesc));
    cublasCheck(cublasLtMatrixLayoutDestroy(weightLayout));
    cublasCheck(cublasLtMatrixLayoutDestroy(inputLayout));
    cublasCheck(cublasLtMatrixLayoutDestroy(outputLayout));
    cublasCheck(cublasLtMatrixLayoutDestroy(biasLayout));
}

void attention_forward(floatX* out, floatX* qkvr, floatX* att,
                       floatX* inp,
                       int B, int T, int C, int NH) {
    NVTX_RANGE_FN();
    // Note: `inp` is not needed for backward pass, so we re-use it as a scratch buffer.
    // Its contents will be overwritten by this function.
    const int block_size = 256;
    const float alpha = 1.0f, beta = 0.0f;

    // inp is (B, T, 3C) QKV
    // preatt, att are (B, NH, T, T)
    // output is (B, T, C)
    int HS = C / NH; // head size

    // permute and separate inp from (B, T, 3, NH, HS) to 3X (B, NH, T, HS)
    floatX *q, *k, *v;
    q = qkvr + 0 * B * T * C;
    k = qkvr + 1 * B * T * C;
    v = qkvr + 2 * B * T * C;
    int total_threads = B * NH * T * HS;
    int num_blocks = CEIL_DIV(total_threads, block_size);
    permute_kernel<<<num_blocks, block_size, 0, main_stream>>>(q, k, v, inp, B, T, NH, HS);


    floatX* preatt = inp;
    cublasCheck(cublasGemmStridedBatchedEx(cublas_handle,
                                     CUBLAS_OP_T, CUBLAS_OP_N,
                                     T, T, HS, &alpha,
                                     k, CUBLAS_LOWP, HS, T * HS,
                                     q, CUBLAS_LOWP, HS, T * HS,
                                     &beta, preatt, CUBLAS_LOWP, T, T * T,
                                     B * NH, cublas_compute, CUBLAS_GEMM_DEFAULT));

    // multiply all elements of preatt elementwise by scale
    float scale = 1.0 / sqrtf(HS);
    int grid_size = CEIL_DIV(B * NH * T * 32, block_size);
    softmax_forward_kernel5<<<grid_size, block_size, 0, main_stream>>>(att, scale, preatt, B * NH, T);

    // new approach: first cuBLAS another batched matmul
    floatX* vaccum = inp;
    // y = att @ v # (B, nh, T, T) @ (B, nh, T, hs) -> (B, nh, T, hs)
    cublasCheck(cublasGemmStridedBatchedEx(cublas_handle,
                                     CUBLAS_OP_N, CUBLAS_OP_N,
                                     HS, T, T, &alpha,
                                     v, CUBLAS_LOWP, HS, T * HS,
                                     att, CUBLAS_LOWP, T, T * T,
                                     &beta, vaccum, CUBLAS_LOWP, HS, T * HS,
                                     B * NH, cublas_compute, CUBLAS_GEMM_DEFAULT));

    // now unpermute
    // y = y.transpose(1, 2).contiguous().view(B, T, C) # re-assemble all head outputs side by side
    num_blocks = CEIL_DIV(B * T * C, block_size);
    unpermute_kernel<<<num_blocks, block_size, 0, main_stream>>>(vaccum, out, B, T, NH, HS);
    cudaCheck(cudaGetLastError());
}

void residual_forward(floatX* out, floatX* inp1, floatX* inp2, int N) {
    NVTX_RANGE_FN();
    const int block_size = 256;
    const int grid_size = CEIL_DIV(N, block_size * x128::size);
    residual_forward_kernel<<<grid_size, block_size, 0, main_stream>>>(out, inp1, inp2, N);
    cudaCheck(cudaGetLastError());
}

void gelu_forward(floatX* out, const floatX* inp, int N) {
    NVTX_RANGE_FN();
    const int block_size = 512;
    const int grid_size = CEIL_DIV(N, block_size * x128::size);
    gelu_forward_kernel2<<<grid_size, block_size, 0, main_stream>>>(out, inp, N);
    cudaCheck(cudaGetLastError());
}

void gelu_backward(floatX* dinp, const floatX* inp, const floatX* dout, const int N) {
    NVTX_RANGE_FN();
    const int block_size = 128;
    const int grid_size = CEIL_DIV(N, block_size * x128::size);
    gelu_backward_kernel<<<grid_size, block_size, 0, main_stream>>>(dinp, inp, dout, N);
    cudaCheck(cudaGetLastError());
}

void matmul_backward(floatX* dinp, floatX* dweight, floatX* dbias,
                     floatX* dout, floatX* inp, floatX* weight,
                     float* dbias_buffer,
                     int B, int T, int C, int OC) {
    NVTX_RANGE_FN();
    float one = 1.0f, zero = 0.0f;

    // backward to bias, if given, does a +=
    if (dbias != NULL) {
        // Each warp is responsible for 32 * "x128::size" = 256 OCs at BF16 (OC must be a multiple of 256!)
        // Block size is 512 threads (16 warps) and we reduce those 16 values into 1 at the end
        // blockDim.x is 32 --> single warp being responsible for those 256 OCs
        // blockDim.y is 16 --> 16 parallel independent warps processing the same OCs for different BTs
        // gridDim.x is OC / 256 --> each block processes 256 OCs
        // grimDim.y is max(1, (cuda_num_SMs * threads_per_SM) / (512 * gridDim.x)); --> fill up the entire GPU!
        const int warp_size = 32;
        const int block_size = 512;
        const int OC_per_warp = warp_size * x128::size; // 256 at BF16
        const int block_size_x = 32;
        const int block_size_y = block_size / block_size_x; // 16
        const int grid_size_x = OC / OC_per_warp; // e.g. 3 horizontal blocks for 768 OCs at BF16
        const int grid_size_y = max(1, deviceProp.maxThreadsPerMultiProcessor * deviceProp.multiProcessorCount
                                     / (block_size * grid_size_x)); // full GPU!

        assert((OC % OC_per_warp) == 0); // there is no bounds checking in the kernel to maximise performance
        assert(block_size_y >= x128::size); // part of the kernel assumes this is large enough to avoid loops

        cudaMemsetAsync(dbias_buffer, 0, OC * sizeof(float), main_stream);
        matmul_backward_bias_kernel7<<<dim3(grid_size_x, grid_size_y),
                                       dim3(block_size_x, block_size_y),
                                       OC_per_warp * sizeof(float), main_stream>>>(dbias_buffer, dout, B, T, OC);
        cast_and_add_kernel<<<CEIL_DIV(OC, 256), 256, 0, main_stream>>>(dbias, dbias_buffer, OC);
    }

    // backward to input, uses = in the backward pass (set the gradient)
    cublasCheck(cublasGemmEx(cublas_handle, CUBLAS_OP_N, CUBLAS_OP_N, C, B*T, OC, &one,
                             weight, CUBLAS_LOWP, C, dout, CUBLAS_LOWP, OC, &zero,
                             dinp, CUBLAS_LOWP, C, cublas_compute, CUBLAS_GEMM_DEFAULT_TENSOR_OP));
    // backward to weight, uses += in the backward pass (accumulate the gradient) by setting alpha=one
    cublasCheck(cublasGemmEx(cublas_handle, CUBLAS_OP_N, CUBLAS_OP_T, C, OC, B*T, &one,
                             inp, CUBLAS_LOWP, C, dout, CUBLAS_LOWP, OC, &one,
                             dweight, CUBLAS_LOWP, C, cublas_compute, CUBLAS_GEMM_DEFAULT_TENSOR_OP));
    cudaCheck(cudaGetLastError());
}

void layernorm_backward(floatX* dinp, floatX* dweight, floatX* dbias, float* scratch,
                        const floatX* dout, const floatX* inp, const floatX* weight, const floatX* mean, const floatX* rstd,
                        int B, int T, int C) {
    NVTX_RANGE_FN();
    // todo - forcing 3 x 512 threads per SM maximum is a bit hacky, but more than that results in
    // cache thrashing and lower performance on A100... is there a better way?
    const int block_size = 512;
    const int blocks_per_sm = min(3, (deviceProp.maxThreadsPerMultiProcessor / 1024));
    const int grid_size = blocks_per_sm * deviceProp.multiProcessorCount;
    size_t shared_mem_size = (2 * C + 1) * sizeof(float);

    cudaMemsetAsync(scratch, 0, (2 * C + 1) * sizeof(float), main_stream);
    layernorm_backward_kernel8<<<grid_size, block_size, shared_mem_size, main_stream>>>(dinp, dweight, dbias, scratch, dout, inp, weight, mean, rstd, B, T, C);
    cudaCheck(cudaGetLastError());
}


// the sequence of transformations in this compound op is:
// inp (B,T,3C) -> qkvr (B,T,3C) -> preatt (B,NH,T,T) -> att (B,NH,T,T) -> vaccum (B,T,C) -> out (B,T,C)
void attention_backward(floatX* dinp, floatX* dqkvr, floatX* dpreatt, floatX* datt, floatX* scratch,
                        const floatX* dout,
                        const floatX* qkvr, const floatX* att,
                        int B, int T, int C, int NH) {
    NVTX_RANGE_FN();
    const int block_size = 256;
    int HS = C / NH; // head size
    const float alpha = 1.0f, beta = 0.0f;

    // unpack convenience pointers into q, k, v
    const floatX *q, *k, *v;
    q = qkvr + 0 * B * T * C;
    k = qkvr + 1 * B * T * C;
    v = qkvr + 2 * B * T * C;
    floatX *dq, *dk, *dv;
    dq = dqkvr + 0 * B * T * C;
    dk = dqkvr + 1 * B * T * C;
    dv = dqkvr + 2 * B * T * C;

    // backward through the unpermute operation
    int num_blocks = CEIL_DIV(B * T * C, block_size);
    unpermute_kernel_backward<<<num_blocks, block_size, 0, main_stream>>>(scratch, dout, B, T, NH, HS);
    // backward into datt
    cublasCheck(cublasGemmStridedBatchedEx(cublas_handle, CUBLAS_OP_T, CUBLAS_OP_N, T, T, HS, &alpha,
                                           v, CUBLAS_LOWP, HS, T * HS, scratch, CUBLAS_LOWP, HS, T * HS, &beta,
                                           datt, CUBLAS_LOWP, T, T * T, B * NH, cublas_compute, CUBLAS_GEMM_DEFAULT));
    // backward into dv
    cublasCheck(cublasGemmStridedBatchedEx(cublas_handle, CUBLAS_OP_N, CUBLAS_OP_T, HS, T, T, &alpha,
                                           scratch, CUBLAS_LOWP, HS, T * HS, att, CUBLAS_LOWP, T, T * T, &beta,
                                           dv, CUBLAS_LOWP, HS, T * HS, B * NH, cublas_compute, CUBLAS_GEMM_DEFAULT));
    // backward into preatt
    int hs = C / NH; // head size
    float scale = 1.0f / sqrtf(hs);
    softmax_autoregressive_backward_kernel<<<dim3(T / 4, B * NH), 256, 256, main_stream>>>(dpreatt, datt, att, B, T, C, scale);
    // backward into q
    cublasCheck(cublasGemmStridedBatchedEx(cublas_handle, CUBLAS_OP_N, CUBLAS_OP_N, HS, T, T, &alpha,
                                           k, CUBLAS_LOWP, HS, T * HS, dpreatt, CUBLAS_LOWP, T, T * T, &beta,
                                           dq, CUBLAS_LOWP, HS, T * HS, B * NH, cublas_compute, CUBLAS_GEMM_DEFAULT));
    // backward into k
    cublasCheck(cublasGemmStridedBatchedEx(cublas_handle, CUBLAS_OP_N, CUBLAS_OP_T, HS, T, T, &alpha,
                                           q, CUBLAS_LOWP, HS, T * HS, dpreatt, CUBLAS_LOWP, T, T * T, &beta,
                                           dk, CUBLAS_LOWP, HS, T * HS, B * NH, cublas_compute, CUBLAS_GEMM_DEFAULT));
    // backward into inp
    num_blocks = CEIL_DIV(B * NH * T * HS, block_size);
    permute_kernel_backward<<<num_blocks, block_size, 0, main_stream>>>(dinp, dq, dk, dv, B, T, NH, HS);
    cudaCheck(cudaGetLastError());
}

// replaces logits with logit gradients
template <typename Type>
void fused_classifier(Type* logits, Type* losses,
                      const Type* dlosses, const int* targets,
                      int B, int T, int V, int P) {
    NVTX_RANGE_FN();
    const int block_size = 1024;
    const int N = B * T;
    const int grid_size = N;
    fused_classifier_kernel5<<<grid_size, block_size, 512, main_stream>>>(logits, losses, (Type*)NULL, dlosses, targets, B, T, V, P);
    cudaCheck(cudaGetLastError());
}

// ----------------------------------------------------------------------------
// GPT-2 model definition

typedef struct {
    int max_seq_len; // max sequence length, e.g. 1024
    int vocab_size; // vocab size, e.g. 50257
    int padded_vocab_size; // padded to e.g. %128==0, 50304
    int num_layers; // number of layers, e.g. 12
    int num_heads; // number of heads in attention, e.g. 12
    int channels; // number of channels, e.g. 768
} GPT2Config;

// the parameters of the model
constexpr const int NUM_PARAMETER_TENSORS = 16;
typedef struct {
    floatX* wte; // (V, C)
    floatX* wpe; // (maxT, C)
    floatX* ln1w; // (L, C)
    floatX* ln1b; // (L, C)
    floatX* qkvw; // (L, 3*C, C)
    floatX* qkvb; // (L, 3*C)
    floatX* attprojw; // (L, C, C)
    floatX* attprojb; // (L, C)
    floatX* ln2w; // (L, C)
    floatX* ln2b; // (L, C)
    floatX* fcw; // (L, 4*C, C)
    floatX* fcb; // (L, 4*C)
    floatX* fcprojw; // (L, C, 4*C)
    floatX* fcprojb; // (L, C)
    floatX* lnfw; // (C)
    floatX* lnfb; // (C)
} ParameterTensors;
static_assert(sizeof(ParameterTensors) == NUM_PARAMETER_TENSORS * sizeof(void*), "Inconsistent sizes!");

void fill_in_parameter_sizes(size_t* param_sizes, size_t* param_sizeof, GPT2Config config) {
    size_t Vp = config.padded_vocab_size;
    size_t C = config.channels;
    size_t maxT = config.max_seq_len;
    size_t L = config.num_layers;
    param_sizes[0] = Vp * C; // wte
    param_sizes[1] = maxT * C; // wpe
    param_sizes[2] = L * C; // ln1w
    param_sizes[3] = L * C; // ln1b
    param_sizes[4] = L * (3 * C) * C; // qkvw
    param_sizes[5] = L * (3 * C); // qkvb
    param_sizes[6] = L * C * C; // attprojw
    param_sizes[7] = L * C; // attprojb
    param_sizes[8] = L * C; // ln2w
    param_sizes[9] = L * C; // ln2b
    param_sizes[10] = L * (4 * C) * C; // fcw
    param_sizes[11] = L * (4 * C); // fcb
    param_sizes[12] = L * C * (4 * C); // fcprojw
    param_sizes[13] = L * C; // fcprojb
    param_sizes[14] = C; // lnfw
    param_sizes[15] = C; // lnfb

    // populate the parameter sizes in bytes (all the same for now, keeping for future use)
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        param_sizeof[i] = sizeof(floatX);
    }
}

// allocate memory for the parameters and point the individual tensors to the right places
void* malloc_and_point_parameters(ParameterTensors* params, size_t* param_elements, size_t *param_sizeof) {
    // calculate the total number of parameters and bytes across all tensors
    size_t num_parameters = 0;
    size_t num_parameters_bytes = 0;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        num_parameters += param_elements[i];
        num_parameters_bytes += param_elements[i] * param_sizeof[i];
    }
    // malloc all parameters all at once on the device
    void* params_memory;
    cudaCheck(cudaMalloc((void**)&params_memory, num_parameters_bytes));
    // assign all the tensors their place in the array
    floatX** ptrs[] = {
        &params->wte, &params->wpe, &params->ln1w, &params->ln1b, &params->qkvw, &params->qkvb,
        &params->attprojw, &params->attprojb, &params->ln2w, &params->ln2b, &params->fcw, &params->fcb,
        &params->fcprojw, &params->fcprojb, &params->lnfw, &params->lnfb
    };
    char* params_memory_iterator = (char*)params_memory;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        *(ptrs[i]) = (floatX*)params_memory_iterator;
        params_memory_iterator += param_elements[i] * param_sizeof[i];
    }
    return params_memory;
}

#define NUM_ACTIVATION_TENSORS 20
typedef struct {
    floatX* encoded; // (B, T, C)
    floatX* ln1; // (L, B, T, C)
    floatX* ln1_mean; // (L, B, T)
    floatX* ln1_rstd; // (L, B, T)
    floatX* atty; // (L, B, T, C)
    floatX* att; // (L, B, NH, T, T) (smaller with cuDNN)
    floatX* attproj; // (L, B, T, C)
    floatX* residual2; // (L, B, T, C)
    floatX* ln2; // (L, B, T, C)
    floatX* ln2_mean; // (L, B, T)
    floatX* ln2_rstd; // (L, B, T)
    floatX* fch; // (L, B, T, 4*C)
    floatX* fch_gelu; // (L, B, T, 4*C)
    floatX* fcproj; // (L, B, T, C)
    floatX* residual3; // (L, B, T, C)
    floatX* lnf; // (B, T, C)
    floatX* lnf_mean; // (B, T)
    floatX* lnf_rstd; // (B, T)
    // adding these two compared to the CPU .c code, needed for attention kernel as buffers
    floatX* qkvr; // (L, B, T, 3*C)
    // in inference mode, this buffer will store the logits
    // in training mode, this buffer will contain the *gradients* of the logits.
    // during the processing of transformer blocks, we will also use this as a
    // general scratchpad buffer. Allocation is made large enough to hold (B, T, 3C),
    // (B, NH, T, T), and (B, T, V) shaped tensors.
    floatX* output;
} ActivationTensors;

void fill_in_activation_sizes(size_t* act_sizes, size_t B, size_t T, GPT2Config config) {
    size_t Vp = config.padded_vocab_size;
    size_t L = config.num_layers;
    size_t NH = config.num_heads;
    size_t C = config.channels;
    act_sizes[0] = B * T * C; // encoded
    act_sizes[1] = L * B * T * C; // ln1
    act_sizes[2] = L * B * T; // ln1_mean
    act_sizes[3] = L * B * T; // ln1_rstd
    act_sizes[4] = L * B * T * C; // atty
    #ifdef ENABLE_CUDNN
    // FP32 stats tensor for cuDNN to be passed to backward pass
    act_sizes[5] = L * B * NH * T * (sizeof(float) / sizeof(floatX));
    #else
    act_sizes[5] = L * B * NH * T * T; // att
    #endif
    act_sizes[6] = L * B * T * C; // attproj
    act_sizes[7] = L * B * T * C; // residual2
    act_sizes[8] = L * B * T * C; // ln2
    act_sizes[9] = L * B * T; // ln2_mean
    act_sizes[10] = L * B * T; // ln2_rstd
    act_sizes[11] = L * B * T * 4*C; // fch
    act_sizes[12] = L * B * T * 4*C; // fch_gelu
    act_sizes[13] = L * B * T * C; // fcproj
    act_sizes[14] = L * B * T * C; // residual3
    act_sizes[15] = B * T * C; // lnf
    act_sizes[16] = B * T; // lnf_mean
    act_sizes[17] = B * T; // lnf_rstd
    act_sizes[18] = L * B * T * 3*C; // qkvr
    act_sizes[19] = B * T * max(3*C, max(NH*T, Vp)); // output / scratch
}

// Backward pass is conceptually quite different from forward, because we can discard
// the activations of a layer as soon as we're done with it. This lets us aggressively
// reuse memory, so that we need far fewer tensors for backward state.
#ifdef ENABLE_CUDNN
#define NUM_BACKWARD_TENSORS 2
#else
#define NUM_BACKWARD_TENSORS 3
#endif

typedef struct {
    floatX* bt4c; // (B, T, 4*C)
    floatX* residual3; // (B, T, C)
    #ifndef ENABLE_CUDNN
    floatX* preatt; // (B, NH, T, T)
    #endif
} GradActTensors;

void fill_in_grad_act_sizes(size_t* act_sizes, size_t B, size_t T, GPT2Config config) {
    size_t C = config.channels;
    act_sizes[0] = B * T * 4 * C; // bt4c
    act_sizes[1] = B * T * C; // residual3

    #ifndef ENABLE_CUDNN
    size_t NH = config.num_heads;
    act_sizes[2] = B * NH * T * T; // preatt
    #endif
}

void* malloc_and_point(floatX** targets[], const size_t* act_sizes, size_t n) {
    size_t num_activations = 0;
    for (size_t i = 0; i < n; i++) {
        num_activations += act_sizes[i];
    }
    void* acts_memory;
    cudaCheck(cudaMalloc((void**)&acts_memory, num_activations * sizeof(floatX)));
    char* acts_memory_iterator = (char*)acts_memory;
    for (size_t i = 0; i < n; i++) {
        *(targets[i]) = (floatX*)acts_memory_iterator;
        acts_memory_iterator += act_sizes[i] * sizeof(floatX);
    }
    return acts_memory;
}

void* malloc_and_point_activations(ActivationTensors* acts, const size_t* act_sizes) {
    floatX** ptrs[] = {
        &acts->encoded, &acts->ln1, &acts->ln1_mean, &acts->ln1_rstd, &acts->atty,
        &acts->att, &acts->attproj, &acts->residual2, &acts->ln2, &acts->ln2_mean,
        &acts->ln2_rstd, &acts->fch, &acts->fch_gelu, &acts->fcproj, &acts->residual3, &acts->lnf,
        &acts->lnf_mean, &acts->lnf_rstd, &acts->qkvr, &acts->output
    };
    return malloc_and_point(ptrs, act_sizes, NUM_ACTIVATION_TENSORS);
}

void* malloc_and_point_backward(GradActTensors* acts, const size_t* act_sizes) {
    floatX** ptrs[] = {
        &acts->bt4c, &acts->residual3,
        #ifndef ENABLE_CUDNN
        &acts->preatt,
        #endif
    };
    return malloc_and_point(ptrs, act_sizes, NUM_BACKWARD_TENSORS);
}

typedef struct {
    GPT2Config config;
    // the weights of the model, and their sizes
    ParameterTensors params;
    size_t param_elements[NUM_PARAMETER_TENSORS];
    size_t param_sizeof[NUM_PARAMETER_TENSORS];
    void* params_memory;
    size_t num_parameters;
    size_t num_parameters_bytes;
    // gradients of the weights
    ParameterTensors grads;
    void* grads_memory;
    // buffers for the AdamW optimizer
    float* m_memory;
    float* v_memory;
    float* master_weights;     // is NULL unless fp32 weights is enabled.
    // the activations of the model, and their sizes
    ActivationTensors acts;
    size_t act_sizes[NUM_ACTIVATION_TENSORS];
    void* acts_memory;
    size_t num_activations;
    // gradients of the activations
    GradActTensors grads_acts;
    size_t num_grad_acts;
    void* grads_acts_memory;
    // other run state configuration
    int batch_size; // the batch size (B) of current forward pass
    int seq_len; // the sequence length (T) of current forward pass
    int* inputs; // the input tokens for the current forward pass
    int* targets; // the target tokens for the current forward pass
    float mean_loss; // after a forward pass with targets, will be populated with the mean loss
    float accumulated_mean_loss; // Mean loss after aggregating it on all GPUs
    floatX* cpu_losses; // CPU buffer to copy the losses to, allocated with cudaMallocHost
    unsigned long long rng_state; // the RNG state for seeding stochastic rounding etc.
    int use_master_weights;
} GPT2;

void gpt2_build_from_checkpoint(GPT2 *model, const char* checkpoint_path) {

    if (PRECISION_MODE == PRECISION_FP16) {
        // TODO for later perhaps, would require us dynamically converting the
        // model weights from fp32 to fp16 online, here in this function, or writing
        // the fp16 weights directly from Python, which we only do for fp32/bf16 atm.
        fprintf(stderr, "build_from_checkpoint() does not support fp16 right now.\n");
        exit(EXIT_FAILURE);
    }

    // read in model from a checkpoint file
    FILE *model_file = fopenCheck(checkpoint_path, "rb");
    int model_header[256];
    freadCheck(model_header, sizeof(int), 256, model_file);
    if (model_header[0] != 20240326) { printf("Bad magic model file\n"); exit(EXIT_FAILURE); }
    int version = model_header[1];
    if (!(version == 3 || version == 5)) {
        // 3 = fp32, padded vocab
        // 5 = bf16, padded vocab, layernorms also in bf16
        fprintf(stderr, "Bad version in model file\n");
        fprintf(stderr, "---> HINT: try to re-run `python train_gpt2.py`\n");
        exit(EXIT_FAILURE);
    }

    // read in hyperparameters
    model->config.max_seq_len = model_header[2];
    model->config.vocab_size = model_header[3];
    model->config.num_layers = model_header[4];
    model->config.num_heads = model_header[5];
    model->config.channels = model_header[6];
    model->config.padded_vocab_size = model_header[7];

    // allocate space for all the parameters and read them in
    fill_in_parameter_sizes(model->param_elements, model->param_sizeof, model->config);

    model->num_parameters = 0;
    model->num_parameters_bytes = 0;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        model->num_parameters += model->param_elements[i];
        model->num_parameters_bytes += model->param_elements[i] * model->param_sizeof[i];
    }

    // create memory for model parameters on the device
    model->params_memory = malloc_and_point_parameters(&model->params, model->param_elements, model->param_sizeof);

    // read in all the parameters from file and copy them to device
    float* params_memory_cpu = (float*)mallocCheck(model->num_parameters_bytes);
    freadCheck(params_memory_cpu, 1, model->num_parameters_bytes, model_file);
    cudaCheck(cudaMemcpy(model->params_memory, params_memory_cpu, model->num_parameters_bytes, cudaMemcpyHostToDevice));
    free(params_memory_cpu);
    fcloseCheck(model_file);

    // other inits
    model->acts_memory = NULL;
    model->grads_memory = NULL;
    model->m_memory = NULL;
    model->v_memory = NULL;
    model->master_weights = NULL;
    model->grads_acts_memory = NULL;
    model->inputs = NULL;
    model->targets = NULL;
    model->cpu_losses = NULL;
    model->batch_size = 0;
    model->seq_len = 0;
    model->mean_loss = -1.0f; // -1.0f will designate no loss
    model->rng_state = 13371337;
    model->use_master_weights = 1; // keep master weights copy in float for optim update?
}

void gpt2_forward(GPT2 *model, int* inputs, int* targets, size_t B, size_t T, bool get_loss=true) {
    NVTX_RANGE_FN();
    // targets are optional and could be NULL
    // in this function we must be careful and use size_t instead of int, otherwise
    // we could overflow int. E.g. l * B * NH * T * T overflows int at B 16.

    // ensure the model was initialized or error out
    if (model->params_memory == NULL) {
        printf("Error: model was not initialized properly.\n");
        exit(EXIT_FAILURE);
    }

    // convenience parameters
    size_t V = model->config.vocab_size;
    size_t Vp = model->config.padded_vocab_size;
    size_t L = model->config.num_layers;
    size_t NH = model->config.num_heads;
    size_t C = model->config.channels;

    // validate inputs, all indices must be in the range [0, V)
    for(int i = 0; i < B * T; i++) {
        assert(0 <= inputs[i] && inputs[i] < V);
        if (targets != NULL) {
            assert(0 <= targets[i] && targets[i] < V);
        }
    }

    // allocate space for all the activations if needed (done here, lazily)
    if(model->acts_memory == NULL) {
        // record the current B,T as well
        model->batch_size = B;
        model->seq_len = T;
        // allocate the space
        fill_in_activation_sizes(model->act_sizes, B, T, model->config);
        size_t num_activations = 0;
        for (size_t i = 0; i < NUM_ACTIVATION_TENSORS; i++) {
            num_activations += model->act_sizes[i];
        }
        model->num_activations = num_activations;
        model->acts_memory = malloc_and_point_activations(&model->acts, model->act_sizes);
        printf0("allocated %d MiB for activations\n", (int)round(num_activations * sizeof(floatX) / (1024 * 1024)));
        // also create memory for caching inputs and targets
        cudaCheck(cudaMalloc((void**)&model->inputs, B * T * sizeof(int)));
        cudaCheck(cudaMalloc((void**)&model->targets, B * T * sizeof(int)));
        cudaCheck(cudaMallocHost((void**)&model->cpu_losses, B * T * sizeof(floatX)));
    } else {
        // validate B,T is consistent with how we've allocated the memory before
        // in principle we could get more clever here in the future, for now this is safest
        if (B != model->batch_size || T != model->seq_len) {
            printf("Model: B=%d T=%d, Desired: B=%d T=%d\n", model->batch_size, model->seq_len, (int)B, (int)T);
            exit(EXIT_FAILURE);
        }
    }

    // copy inputs/targets to the model
    // todo - inputs is copied on default stream so this synchronises CPU/GPU for now
    cudaCheck(cudaMemcpyAsync(model->inputs, inputs, B * T * sizeof(int), cudaMemcpyHostToDevice, 0));
    if (targets != NULL) {
        // memcpy targets in parallel then wait for them before fused_classifier
        cudaCheck(cudaMemcpyAsync(model->targets, targets, B * T * sizeof(int), cudaMemcpyHostToDevice, parallel_streams[0]));
        cudaEventRecord(parallel_events[0], parallel_streams[0]);
    }

    // forward pass
    ParameterTensors params = model->params; // for brevity
    ActivationTensors acts = model->acts;
    floatX* residual;
    encoder_forward(acts.encoded, model->inputs, params.wte, params.wpe, B, T, C); // encoding goes into residual[0]

    for (int l = 0; l < L; l++) {
        NvtxRange layer_range("Layer", l);

        residual = l == 0 ? acts.encoded : acts.residual3 + (l-1) * B * T * C;

        // get the pointers of the weights for this layer
        floatX* l_ln1w = params.ln1w + l * C;
        floatX* l_ln1b = params.ln1b + l * C;
        floatX* l_qkvw = params.qkvw + l * 3*C * C;
        floatX* l_qkvb = params.qkvb + l * 3*C;
        floatX* l_attprojw = params.attprojw + l * C * C;
        floatX* l_attprojb = params.attprojb + l * C;
        floatX* l_ln2w = params.ln2w + l * C;
        floatX* l_ln2b = params.ln2b + l * C;
        floatX* l_fcw = params.fcw + l * 4*C * C;
        floatX* l_fcb = params.fcb + l * 4*C;
        floatX* l_fcprojw = params.fcprojw + l * C * 4*C;
        floatX* l_fcprojb = params.fcprojb + l * C;

        // get the pointers of the activations for this layer
        floatX* l_ln1 = acts.ln1 + l * B * T * C;
        floatX* l_ln1_mean = acts.ln1_mean + l * B * T;
        floatX* l_ln1_rstd = acts.ln1_rstd + l * B * T;
        floatX* l_qkvr = acts.qkvr + l * B * T * 3*C;
        floatX* l_atty = acts.atty + l * B * T * C;
        floatX* l_attproj = acts.attproj + l * B * T * C;
        floatX* l_residual2 = acts.residual2 + l * B * T * C;
        floatX* l_ln2 = acts.ln2 + l * B * T * C;
        floatX* l_ln2_mean = acts.ln2_mean + l * B * T;
        floatX* l_ln2_rstd = acts.ln2_rstd + l * B * T;
        floatX* l_fch = acts.fch + l * B * T * 4*C;
        floatX* l_fch_gelu = acts.fch_gelu + l * B * T * 4*C;
        floatX* l_fcproj = acts.fcproj + l * B * T * C;
        floatX* l_residual3 = acts.residual3 + l * B * T * C;

        // now do the forward pass
        layernorm_forward(l_ln1, l_ln1_mean, l_ln1_rstd, residual, l_ln1w, l_ln1b, B, T, C);

        #ifdef ENABLE_CUDNN
        float* l_att = (float*)acts.att + l * B * NH * T; // cuDNN needs a smaller FP32 tensor
        matmul_forward_cublaslt(l_qkvr, l_ln1, l_qkvw, l_qkvb, B, T, C, 3*C);
        attention_forward_cudnn(l_atty, (float*)l_att, l_qkvr, B, T, NH, C);
        #else
        floatX* l_att = acts.att + l * B * NH * T * T;
        // these are only needed as scratchpads for the forward pass, but
        // need not be stored for backward
        floatX* scratch = (floatX*)acts.output;
        matmul_forward_cublaslt(scratch, l_ln1, l_qkvw, l_qkvb, B, T, C, 3*C);
        attention_forward(l_atty, l_qkvr, l_att, scratch, B, T, C, NH);
        #endif

        matmul_forward_cublaslt(l_attproj, l_atty, l_attprojw, l_attprojb, B, T, C, C);
        residual_forward(l_residual2, residual, l_attproj, B*T*C);
        layernorm_forward(l_ln2, l_ln2_mean, l_ln2_rstd, l_residual2, l_ln2w, l_ln2b, B, T, C);
        matmul_forward_cublaslt(l_fch, l_ln2, l_fcw, l_fcb, B, T, C, 4*C);
        gelu_forward(l_fch_gelu, l_fch, B*T*4*C);
        matmul_forward_cublaslt(l_fcproj, l_fch_gelu, l_fcprojw, l_fcprojb, B, T, 4*C, C);
        residual_forward(l_residual3, l_residual2, l_fcproj, B*T*C);
    }

    residual = acts.residual3 + (L-1) * B * T * C; // last residual is in residual3
    layernorm_forward(acts.lnf, acts.lnf_mean, acts.lnf_rstd, residual, params.lnfw, params.lnfb, B, T, C);
    matmul_forward_cublaslt(acts.output, acts.lnf, params.wte, NULL, B, T, C, Vp);

    // also forward the cross-entropy loss function if we have the targets
    if (targets != NULL) {
        NvtxRange classifier_and_loss_range("classifier_and_loss");
        // wait on memcpy of targets (definitely finished by now, but better safe than sorry)
        cudaStreamWaitEvent(main_stream, parallel_events[0], 0);
        // fused classifier: does the forward pass and first part of the backward pass
        // we're passing dlosses = NULL, which will default them to 1.0f/(B*T), i.e. uniform loss
        fused_classifier(acts.output, model->cpu_losses, (floatX*)NULL, model->targets, B, T, V, Vp);

        // the GPU now writes the losses directly to the CPU buffer allocated with cudaMallocHost()
        // we accumulate cpu_losses at the end of gpt2_backward() waiting on this event
        cudaEventRecord(loss_event, main_stream);

        // reset mean_loss here so gpt2_backward() knows we have targets
        model->mean_loss = 0.0f;
    } else {
        // if we don't have targets, we don't have loss
        model->mean_loss = -1.0f;
    }

    // accumulate the loss immediately if we are not going to run gpt2_backward(), e.g. inference
    if (get_loss) {
        cudaCheck(cudaEventSynchronize(loss_event)); // hopefully finished long ago
        for (int i=0; i<B*T; i++) { model->mean_loss += (float)(model->cpu_losses[i]); }
        model->mean_loss /= B*T;
    }
}

void gpt2_zero_grad(GPT2 *model) {
    NVTX_RANGE_FN();
    if (model->grads_memory != NULL) {
        cudaCheck(cudaMemsetAsync(model->grads_memory, 0, model->num_parameters * sizeof(floatX), parallel_streams[0]));
    }
    // Allow this to run in parallel with forward pass, but create a dependency with everything after (backwards pass)
    cudaEventRecord(parallel_events[0], parallel_streams[0]);
    cudaStreamWaitEvent(main_stream, parallel_events[0], 0);
}

void gpt2_backward(GPT2 *model) {
    NVTX_RANGE_FN();
    // double check we forwarded previously, with targets
    if (model->mean_loss == -1.0f) {
        printf("Error: must forward with targets before backward\n");
        exit(EXIT_FAILURE);
    }

    // lazily allocate the memory for gradients of the weights and activations, if needed
    if (model->grads_memory == NULL) {
        // allocate buffers for weight gradients
        model->grads_memory = malloc_and_point_parameters(&model->grads, model->param_elements, model->param_sizeof);
        printf0("allocated %d MiB for parameter gradients\n", (int)round(model->num_parameters * sizeof(floatX) / (1024 * 1024)));
        // we're going to be clever for the activations backward pass. we don't need to exactly
        // mirror the forward pass activations and we will save memory.
        size_t bw_act_sizes[NUM_ACTIVATION_TENSORS];
        fill_in_grad_act_sizes(bw_act_sizes, model->batch_size, model->seq_len, model->config);
        // count up and allocate the space
        model->grads_acts_memory = malloc_and_point_backward(&model->grads_acts, bw_act_sizes);
        model->num_grad_acts = 0;
        for (size_t i = 0; i < NUM_BACKWARD_TENSORS; i++) {
            model->num_grad_acts += bw_act_sizes[i];
        }
        printf0("allocated %d MiB for activation gradients\n", (int)round(model->num_grad_acts * sizeof(floatX) / (1024 * 1024)));
        // init gradients of parameters and activations to zero
        gpt2_zero_grad(model);
    }

    // convenience shortcuts, size_t instead of int so that pointer arithmetics don't overflow
    size_t B = model->batch_size;
    size_t T = model->seq_len;
    size_t Vp = model->config.padded_vocab_size;
    size_t L = model->config.num_layers;
    size_t NH = model->config.num_heads;
    size_t C = model->config.channels;

    // backward pass: go in the reverse order of the forward pass, and call backward() functions
    ParameterTensors params = model->params; // for brevity
    ParameterTensors grads = model->grads;
    ActivationTensors acts = model->acts;
    GradActTensors grads_acts = model->grads_acts;

    // reset residual stream gradients (put here to work with gradient accumulation)
    cudaCheck(cudaMemsetAsync(model->grads_acts.residual3, 0, B * T * C * sizeof(floatX), parallel_streams[0]));
    // allow the memset to run in parallel with the forward pass, but create a dependency with everything after
    cudaEventRecord(parallel_events[0], parallel_streams[0]);
    cudaStreamWaitEvent(main_stream, parallel_events[0], 0);

    // re-use the output buffer of the forward pass as a scratchpad during backward pass
    float* scratchF = (float*)acts.output;

    // we kick off the chain rule by filling in dlosses with 1.0f/(B*T)
    // this was done in the fused classifier kernel as last step of forward pass
    // technically that is a small, inline backward() pass of calculating
    // total, final loss as the mean over all losses over all (B,T) positions in the batch
    // next: backward the classifier matmul
    matmul_backward(grads_acts.bt4c, grads.wte, NULL, acts.output, acts.lnf, params.wte, NULL, B, T, C, Vp);
    // backward the final layernorm
    floatX* residual = acts.residual3 + (L-1) * B * T * C; // last residual is in residual3
    floatX* dresidual = (floatX*)grads_acts.residual3; // the main buffer holding the gradient in the backward pass
    layernorm_backward(dresidual, grads.lnfw, grads.lnfb, scratchF, grads_acts.bt4c, residual, params.lnfw, acts.lnf_mean, acts.lnf_rstd, B, T, C);

    // now backward all the layers
    for (int l = L-1; l >= 0; l--) {
        NvtxRange layer_range("Layer", l);

        residual = l == 0 ? acts.encoded : acts.residual3 + (l-1) * B * T * C;

        // get the pointers of the weights for this layer
        floatX* l_ln1w = params.ln1w + l * C;
        floatX* l_qkvw = params.qkvw + l * 3*C * C;
        floatX* l_attprojw = params.attprojw + l * C * C;
        floatX* l_ln2w = params.ln2w + l * C;
        floatX* l_fcw = params.fcw + l * 4*C * C;
        floatX* l_fcprojw = params.fcprojw + l * C * 4*C;
        // get the pointers of the gradients of the weights for this layer
        floatX* dl_ln1w = grads.ln1w + l * C;
        floatX* dl_ln1b = grads.ln1b + l * C;
        floatX* dl_qkvw = grads.qkvw + l * 3*C * C;
        floatX* dl_qkvb = grads.qkvb + l * 3*C;
        floatX* dl_attprojw = grads.attprojw + l * C * C;
        floatX* dl_attprojb = grads.attprojb + l * C;
        floatX* dl_ln2w = grads.ln2w + l * C;
        floatX* dl_ln2b = grads.ln2b + l * C;
        floatX* dl_fcw = grads.fcw + l * 4*C * C;
        floatX* dl_fcb = grads.fcb + l * 4*C;
        floatX* dl_fcprojw = grads.fcprojw + l * C * 4*C;
        floatX* dl_fcprojb = grads.fcprojb + l * C;
        // get the pointers of the activations for this layer
        floatX* l_ln1 = acts.ln1 + l * B * T * C;
        floatX* l_ln1_mean = acts.ln1_mean + l * B * T;
        floatX* l_ln1_rstd = acts.ln1_rstd + l * B * T;
        floatX* l_qkvr = acts.qkvr + l * B * T * 3*C;
        floatX* l_atty = acts.atty + l * B * T * C;
        floatX* l_residual2 = acts.residual2 + l * B * T * C;
        floatX* l_ln2 = acts.ln2 + l * B * T * C;
        floatX* l_ln2_mean = acts.ln2_mean + l * B * T;
        floatX* l_ln2_rstd = acts.ln2_rstd + l * B * T;
        floatX* l_fch = acts.fch + l * B * T * 4*C;
        floatX* l_fch_gelu = acts.fch_gelu + l * B * T * 4*C;
        // get the pointers of the gradients of the activations for this layer
        // notice that there is no l *, because we just have a single copy, and keep
        // re-using this memory in every Transformer block as we calculate backward pass

        // we need a B x T x C buffer; thankfully, the forward activation for lnf isn't needed anymore,
        // so we can co-opt it here.
        floatX* dl_btc = (floatX*)acts.lnf;
        floatX* dl_bt4c = (floatX*)grads_acts.bt4c;

        // backprop this layer
        matmul_backward(dl_bt4c, dl_fcprojw, dl_fcprojb, dresidual, l_fch_gelu, l_fcprojw, scratchF, B, T, 4*C, C);
        gelu_backward(dl_bt4c, l_fch, dl_bt4c, B*T*4*C);
        matmul_backward(dl_btc, dl_fcw, dl_fcb, dl_bt4c, l_ln2, l_fcw, scratchF, B, T, C, 4 * C);
        // layernorm backward does += to the dresidual, so it correctly accumulates grad from the MLP block above
        layernorm_backward(dresidual, dl_ln2w, dl_ln2b, scratchF, dl_btc, l_residual2, l_ln2w, l_ln2_mean, l_ln2_rstd, B, T, C);
        matmul_backward(dl_btc, dl_attprojw, dl_attprojb, dresidual, l_atty, l_attprojw, scratchF, B, T, C, C);

        #ifdef ENABLE_CUDNN
        float* l_att = (float*)acts.att + l * B * NH * T; // cuDNN needs a smaller FP32 tensor
        attention_backward_cudnn(dl_bt4c, dl_btc, l_qkvr, l_atty, (float*)l_att, B, T, NH, C);
        #else
        floatX* l_att = acts.att + l * B * NH * T * T;
        // we need B x T x (4)C buffers. l_atty and l_fch aren't needed anymore at this point, so reuse their memory
        floatX* buffer_a = l_atty;
        floatX* buffer_b = l_fch;        // this is B x T x 4C, so even larger than what we need
        floatX* dl_preatt = (floatX*)grads_acts.preatt; // dedicated scratchpad allocation
        floatX* scratchX =  (floatX*)acts.output;
        attention_backward(dl_bt4c, buffer_b, dl_preatt, scratchX, buffer_a, dl_btc, l_qkvr, l_att, B, T, C, NH);
        #endif

        // QKV parameter gradients
        matmul_backward(dl_btc, dl_qkvw, dl_qkvb, dl_bt4c, l_ln1, l_qkvw, scratchF, B, T, C, 3 * C);
        // layernorm backward does += to dresidual, so it correctly accumulates gradient for the Attention block above
        layernorm_backward(dresidual, dl_ln1w, dl_ln1b, scratchF, dl_btc, residual, l_ln1w, l_ln1_mean, l_ln1_rstd, B, T, C);
    }
    encoder_backward(grads.wte, grads.wpe, dresidual, model->inputs, B, T, C, random_u32(&model->rng_state));

    // accumulate the loss, this was calculated at the end of gpt2_forward()
    cudaCheck(cudaEventSynchronize(loss_event)); // hopefully finished long ago
    for (int i=0; i<B*T; i++) { model->mean_loss += (float)(model->cpu_losses[i]); }
    model->mean_loss /= B*T;
}

// Compute a mean of a single CPU value across all GPU processes. No-op when multi-GPU is disabled.
float multi_gpu_cpu_float_mean(float value, const MultiGpuConfig* multi_gpu_config) {
#ifdef MULTI_GPU
    // MPI doesn't support all reduce with mean, so we sum up, then divide.
    float result;
    mpiCheck(MPI_Allreduce(&value, &result, 1, MPI_FLOAT, MPI_SUM, MPI_COMM_WORLD));
    return result / multi_gpu_config->num_processes;
#else
    return value;
#endif
}

// Averages out the loss and gradients across all GPUs. No-op when multi-GPU is disabled.
// todo - this version only works if all the parameters are the same size (floatX)
void gpt2_multi_gpu_accumulate(GPT2* model, MultiGpuConfig* multi_gpu_config) {
    NVTX_RANGE_FN();
    // Average all losses.
    model->accumulated_mean_loss = multi_gpu_cpu_float_mean(model->mean_loss, multi_gpu_config);
#ifdef MULTI_GPU
    // Average all gradients.
    ncclCheck(ncclAllReduce(model->grads_memory, model->grads_memory,
        model->num_parameters,
        ncclFloatX, ncclAvg,
        multi_gpu_config->nccl_comm,
        main_stream));
#endif
}

void gpt2_update(GPT2 *model, float learning_rate, float beta1, float beta2, float eps, float weight_decay, int t) {
    NVTX_RANGE_FN();
    // reference: https://pytorch.org/docs/stable/generated/torch.optim.AdamW.html

    // lazily allocate the memory for m_memory and v_memory
    if (model->m_memory == NULL) {
        cudaCheck(cudaMalloc((void**)&model->m_memory, model->num_parameters * sizeof(float)));
        cudaCheck(cudaMalloc((void**)&model->v_memory, model->num_parameters * sizeof(float)));
        cudaCheck(cudaMemset(model->m_memory, 0, model->num_parameters * sizeof(float)));
        cudaCheck(cudaMemset(model->v_memory, 0, model->num_parameters * sizeof(float)));
        printf0("allocated %zu MiB for AdamW optimizer state m\n", (model->num_parameters * sizeof(float)) >> 20);
        printf0("allocated %zu MiB for AdamW optimizer state v\n", (model->num_parameters * sizeof(float)) >> 20);
        if (model->use_master_weights == 1) {
            // allocate one more buffer to keep the master copy of weights as float, and copy the weights over
            cudaCheck(cudaMalloc((void**)&model->master_weights, model->num_parameters * sizeof(float)));
            copy_and_cast_kernel<<<CEIL_DIV(model->num_parameters, 512), 512, 0, main_stream>>>(model->master_weights, (floatX*)model->params_memory, model->num_parameters);
            cudaCheck(cudaGetLastError());
            printf0("allocated %zu MiB for master copy of params\n", (model->num_parameters * sizeof(float)) >> 20);
        }
    }

    int block_size = 512;
    int num_blocks = CEIL_DIV(model->num_parameters, block_size);
    float beta1_correction = 1.0f - powf(beta1, t);
    float beta2_correction = 1.0f - powf(beta2, t);
    unsigned int seed = random_u32(&model->rng_state);
    adamw_kernel3<<<num_blocks, block_size, 0, main_stream>>>((floatX*)model->params_memory, model->master_weights,
                                              (floatX*)model->grads_memory, model->m_memory, model->v_memory,
                                              model->num_parameters,
                                              learning_rate, beta1, beta2, beta1_correction, beta2_correction, eps, weight_decay, seed);
    cudaCheck(cudaGetLastError());
}

void gpt2_free(GPT2 *model) {
    cudaCheck(cudaFree(model->params_memory));
    cudaCheck(cudaFree(model->grads_memory));
    cudaCheck(cudaFree(model->m_memory));
    cudaCheck(cudaFree(model->v_memory));
    cudaCheck(cudaFree(model->master_weights));
    cudaCheck(cudaFree(model->acts_memory));
    cudaCheck(cudaFree(model->grads_acts_memory));
    cudaCheck(cudaFree(model->inputs));
    cudaCheck(cudaFree(model->targets));
    cudaFreeHost(model->cpu_losses);
}

// ----------------------------------------------------------------------------
// common init & free code for train/test/profile
void common_start(bool override_enable_tf32 = true, bool print_device_info = true) {
    cudaGetDeviceProperties(&deviceProp, multi_gpu_config.local_device_idx);
    if (print_device_info) {
        printf("[System]\n");
        printf("Device %d: %s\n", multi_gpu_config.local_device_idx, deviceProp.name);
    }

    cudaCheck(cudaStreamCreate(&main_stream));
    cudaEventCreateWithFlags(&main_event, cudaEventDisableTiming);
    cudaEventCreateWithFlags(&loss_event, cudaEventDisableTiming);
    for (int i = 0; i < num_parallel_streams; i++) {
        cudaCheck(cudaStreamCreate(&parallel_streams[i]));
        cudaEventCreateWithFlags(&parallel_events[i], cudaEventDisableTiming);
    }

    // set up cuBLAS and cuBLASLt (and cuDNN if enabled)
    cublasCheck(cublasCreate(&cublas_handle));
    cublasCheck(cublasSetStream(cublas_handle, main_stream));
    cublasCheck(cublasLtCreate(&cublaslt_handle));
    cudaCheck(cudaMalloc(&cublaslt_workspace, cublaslt_workspace_size));

    // TF32 precision is equivalent to torch.set_float32_matmul_precision('high')
    bool enable_tf32 = PRECISION_MODE == PRECISION_FP32 && deviceProp.major >= 8 && override_enable_tf32;
    cublasCheck(cublasSetMathMode(cublas_handle, enable_tf32 ? CUBLAS_TF32_TENSOR_OP_MATH : CUBLAS_DEFAULT_MATH));
    cublas_compute = enable_tf32 ? CUBLAS_COMPUTE_32F_FAST_TF32 : CUBLAS_COMPUTE_32F;
    // setup the (global) cuBLASLt workspace
    cudaCheck(cudaMalloc(&cublaslt_workspace, cublaslt_workspace_size));

    create_cudnn();
}

void common_free(GPT2 &model) {
    cudaCheck(cudaEventDestroy(main_event));
    cudaCheck(cudaEventDestroy(loss_event));
    for (int i = 0; i < num_parallel_streams; i++) {
        cudaCheck(cudaStreamDestroy(parallel_streams[i]));
        cudaCheck(cudaEventDestroy(parallel_events[i]));
    }
    cudaCheck(cudaStreamDestroy(main_stream));

    gpt2_free(&model);
    cudaCheck(cudaFree(cublaslt_workspace));
    cublasCheck(cublasDestroy(cublas_handle));
    cublasCheck(cublasLtDestroy(cublaslt_handle));
    create_cudnn();
}

#ifndef TESTING
// if we are TESTING (see test_gpt2.cu), we'll skip the int main below
// ----------------------------------------------------------------------------
// data loader lite: returns random batches of data from a file of integers

typedef struct {
    // Distributed data parallel specifics.
    // Each worker loads it's own chunk of data.
    int process_rank;
    int num_processes;
    // hyperparameters. use size_t to prevent overflow
    size_t B;
    size_t T;
    // input handling and its state
    FILE* tokens_file;
    long file_size;
    long current_position;
    // output memory
    int* batch;
    int* inputs;
    int* targets;
    // convenience variables
    size_t num_batches;
} DataLoader;

void dataloader_init(DataLoader *loader, const MultiGpuConfig* multi_gpu_config, const char* filename, size_t B, size_t T) {
    loader->process_rank = multi_gpu_config->process_rank;
    loader->num_processes = multi_gpu_config->num_processes;
    loader->B = B;
    loader->T = T;

    // open the input file for reading
    loader->tokens_file = fopenCheck(filename, "rb");

    // determine the file size
    fseekCheck(loader->tokens_file, 0, SEEK_END);
    loader->file_size = ftell(loader->tokens_file);
    fseekCheck(loader->tokens_file, 0, SEEK_SET);
    if (loader->file_size < (B * T + 1) * sizeof(int)) {
        printf("Error: file size is too small for the batch size and sequence length\n");
        exit(EXIT_FAILURE);
    }
    loader->current_position = loader->process_rank * B * T * sizeof(int); // start at the beginning

    // allocate space for B*T + 1 integers to store the inputs and targets
    // Using CUDA CPU pinned memory for faster PCI Express transfers to GPU
    // See: https://developer.nvidia.com/blog/how-optimize-data-transfers-cuda-cc/
    cudaMallocHost((void**)&loader->batch, (B * T + 1) * sizeof(int));
    loader->inputs = loader->batch;
    loader->targets = loader->batch + 1; // targets are shifted by one
    // note: we definitely want to advance by B * T; That is the "stride" by which we move
    // the window of tokens. We only load B * T + 1 tokens because our targets are offset by 1
    loader->num_batches = loader->file_size / (loader->num_processes * B * T * sizeof(int));
}

void dataloader_reset(DataLoader *loader) {
    loader->current_position = 0;
}

void dataloader_next_batch(DataLoader *loader) {
    NVTX_RANGE_FN();
    size_t B = loader->B;
    size_t T = loader->T;
    // if we are at the end of the file, loop back to the beginning
    if (loader->current_position + (loader->num_processes * B * T + 1) * sizeof(int) > loader->file_size) {
        loader->current_position = loader->process_rank * B * T * sizeof(int);
    }
    // read the B*T+1 integers from the file into batch
    fseekCheck(loader->tokens_file, loader->current_position, SEEK_SET);
    freadCheck(loader->batch, sizeof(int), B*T+1, loader->tokens_file);
    // advance the current position by B*T*num_processes integers
    // note: the "stride" of tokens by which we move each time is definitely B * T
    loader->current_position += loader->num_processes * B * T * sizeof(int);
}

void dataloader_free(DataLoader *loader) {
    fcloseCheck(loader->tokens_file);
    cudaFreeHost(loader->batch);
}

// ----------------------------------------------------------------------------
// sampler: takes probabilities and samples integers from them

int sample_softmax(const float* logits, int n, float coin) {
    // sample index from logits (converted to probabilities using softmax)
    // coin is a random number in [0, 1), usually from random_f32()
    double norm = 0;
    for (int i = 0; i < n; i++) {
        norm += expf(logits[i]);
    }
    // instead of dividing all exp(logits), we can just multiply coin.
    coin *= norm;
    float cdf = 0.0f;
    for (int i = 0; i < n; i++) {
        cdf += expf(logits[i]);
        if (coin < cdf) {
            return i;
        }
    }
    return n - 1; // in case of rounding errors
}

// ----------------------------------------------------------------------------
// Logger lite, will probably grow/change some over time

typedef struct {
    FILE *logfile;
    int flush_every; // every how many steps to flush the log
} Logger;

void logger_init(Logger *logger, const char *filename) {
    logger->flush_every = 20;
    logger->logfile = NULL;
    if (filename != NULL) { logger->logfile = fopenCheck(filename, "w"); }
}

void logger_log_val(Logger *logger, int step, float val_loss) {
    if (logger->logfile != NULL) {
        fprintf(logger->logfile, "s:%d tel:%.4f\n", step, val_loss);
    }
}

void logger_log_train(Logger *logger, int step, float train_loss) {
    if (logger->logfile != NULL) {
        fprintf(logger->logfile, "s:%d trl:%.4f\n", step, train_loss);
        if (step % 10 == 0) { fflush(logger->logfile); }
    }
}

void logger_free(Logger *logger) {
    if (logger->logfile != NULL) { fclose(logger->logfile); }
}

// ----------------------------------------------------------------------------
// CLI, poor man's argparse

void error_usage() {
    // default run = debugging run with TinyShakespeare
    // bigger run = train on TinyStories! e.g. val/sample less often, but sample more tokens, write to logfile
    fprintf(stderr, "Usage:   ./train_gpt2cu [options]\n");
    fprintf(stderr, "Example: ./train_gpt2cu -i data/TinyStories -v 100 -s 100 -g 144 -o stories.log\n");
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -i <string> input dataset prefix (default = data/tiny_shakespeare)\n");
    fprintf(stderr, "  -o <string> output log file (default = NULL)\n");
    fprintf(stderr, "  -b <int>    batch size B (default = 4)\n");
    fprintf(stderr, "  -t <int>    sequence length T (default = 1024)\n");
    fprintf(stderr, "  -l <float>  learning rate (default = 3e-4f)\n");
    fprintf(stderr, "  -x <int>    max_steps of optimization to run (-1 (default) = disable, run 1 epoch)\n");
    fprintf(stderr, "  -v <int>    val_loss_every, how often we evaluate val loss (default = 20)\n");
    fprintf(stderr, "  -m <int>    val_max_batches, up to how many val batches to estimate val loss? (default = 20)\n");
    fprintf(stderr, "  -s <int>    sample_every, how often we inference the model (default = 20)\n");
    fprintf(stderr, "  -g <int>    genT, how many steps of inference we do (default = 64)\n");
    fprintf(stderr, "  -a <int>    overfit a single batch? 0/1. useful for debugging\n");
    fprintf(stderr, "  -f <int>    enable_tf32 override (default: 1, set to 0 to disable tf32)\n");
    fprintf(stderr, "  -w <int>    keep f32 copy of weights for the optimizer? (default: 1)\n");
    exit(EXIT_FAILURE);
}

// ----------------------------------------------------------------------------
// main training loop
int main(int argc, char *argv[]) {
    multi_gpu_config = multi_gpu_config_init(&argc, &argv);

    // read in the (optional) command line arguments
    const char* input_dataset_prefix = "data/tiny_shakespeare"; // or e.g. data/TinyStories
    const char* output_log_file = NULL;
    int B = 4; // batch size
    int T = 1024; // sequence length max
    float learning_rate = 3e-4f;
    int val_loss_every = 20; // every how many steps do we eval validation loss?
    int val_max_batches = 20; // how many batches max do we eval for validation loss?
    int sample_every = 20; // every how many steps to do inference?
    int genT = 64; // number of steps of inference we will do
    int overfit_single_batch = 0; // useful for debugging, 1 = only load a single data batch once
    int max_steps = -1;
    int override_enable_tf32 = 1;
    int use_master_weights = 1;
    for (int i = 1; i < argc; i+=2) {
        if (i + 1 >= argc) { error_usage(); } // must have arg after flag
        if (argv[i][0] != '-') { error_usage(); } // must start with dash
        if (strlen(argv[i]) != 2) { error_usage(); } // must be -x (one dash, one letter)
        // read in the args
        if (argv[i][1] == 'i') { input_dataset_prefix = argv[i+1]; }
        else if (argv[i][1] == 'o') { output_log_file = argv[i+1]; }
        else if (argv[i][1] == 'b') { B = atoi(argv[i+1]); } // Per-GPU batch size
        else if (argv[i][1] == 't') { T = atoi(argv[i+1]); }
        else if (argv[i][1] == 'l') { learning_rate = atof(argv[i+1]); }
        else if (argv[i][1] == 'x') { max_steps = atoi(argv[i+1]); }
        else if (argv[i][1] == 'v') { val_loss_every = atoi(argv[i+1]); }
        else if (argv[i][1] == 'm') { val_max_batches = atoi(argv[i+1]); }
        else if (argv[i][1] == 's') { sample_every = atoi(argv[i+1]); }
        else if (argv[i][1] == 'g') { genT = atoi(argv[i+1]); }
        else if (argv[i][1] == 'a') { overfit_single_batch = atoi(argv[i+1]); }
        else if (argv[i][1] == 'f') { override_enable_tf32 = atoi(argv[i+1]); }
        else if (argv[i][1] == 'w') { use_master_weights = atoi(argv[i+1]); }
        else { error_usage(); }
    }
    printf0("+-----------------------+----------------------------------------------------+\n");
    printf0("| Parameter             | Value                                              |\n");
    printf0("+-----------------------+----------------------------------------------------+\n");
    printf0("| input dataset prefix  | %-50s |\n", input_dataset_prefix);
    printf0("| output log file       | %-50s |\n", output_log_file == NULL ? "NULL" : output_log_file);
    printf0("| batch size B          | %-50d |\n", B);
    printf0("| sequence length T     | %-50d |\n", T);
    printf0("| learning rate         | %-50e |\n", learning_rate);
    printf0("| max_steps             | %-50d |\n", max_steps);
    printf0("| val_loss_every        | %-50d |\n", val_loss_every);
    printf0("| val_max_batches       | %-50d |\n", val_max_batches);
    printf0("| sample_every          | %-50d |\n", sample_every);
    printf0("| genT                  | %-50d |\n", genT);
    printf0("| overfit_single_batch  | %-50d |\n", overfit_single_batch);
    printf0("| use_master_weights    | %-50s |\n", use_master_weights ? "enabled" : "disabled");
    printf0("+-----------------------+----------------------------------------------------+\n");

    common_start(override_enable_tf32, false); // common init code for train/test/profile

    const char* precision_str = (PRECISION_MODE == PRECISION_FP32)
                              ? (cublas_compute == CUBLAS_COMPUTE_32F_FAST_TF32 ? "TF32" : "FP32")
                              : (PRECISION_MODE == PRECISION_FP16 ? "FP16" : "BF16");

    printf0("| device                | %-50s |\n", deviceProp.name);
    printf0("| precision             | %-50s |\n", precision_str);
    printf0("+-----------------------+----------------------------------------------------+\n");

    // build the GPT-2 model from a checkpoint
    GPT2 model;
    gpt2_build_from_checkpoint(&model, load_filename);
    model.use_master_weights = use_master_weights;
    printf0("| load_filename         | %-50s |\n", load_filename);
    printf0("| max_sequence_length T | %-50d |\n", model.config.max_seq_len);
    printf0("| vocab_size V          | %-50d |\n", model.config.vocab_size);
    printf0("| padded_vocab_size Vp  | %-50d |\n", model.config.padded_vocab_size);
    printf0("| num_layers L          | %-50d |\n", model.config.num_layers);
    printf0("| num_heads NH          | %-50d |\n", model.config.num_heads);
    printf0("| channels C            | %-50d |\n", model.config.channels);
    printf0("| num_parameters        | %-50zu |\n", model.num_parameters);
    printf0("+-----------------------+----------------------------------------------------+\n");

    // build DataLoaders for both train and val
    char train_tokens_filename[128], val_tokens_filename[128];
    assert(strlen(input_dataset_prefix) < 100); // being bit lazy here, make sure we don't overflow
    // if we're only overfitting a single batch for debugging, let's overfit the first batch
    // from val instead of train split, because val is smaller and a bit faster
    const char* train_split = (overfit_single_batch == 1) ? "val" : "train";
    sprintf(train_tokens_filename, "%s_%s.bin", input_dataset_prefix, train_split);
    sprintf(val_tokens_filename, "%s_val.bin", input_dataset_prefix);
    DataLoader train_loader, val_loader;
    dataloader_init(&train_loader, &multi_gpu_config, train_tokens_filename, B, T);
    dataloader_init(&val_loader, &multi_gpu_config, val_tokens_filename, B, T);
    int train_num_batches = (max_steps == -1) ? train_loader.num_batches : max_steps; // default = 1 epoch
    int val_num_batches = train_loader.num_batches < val_max_batches ? train_loader.num_batches : val_max_batches;
    printf0("| train_num_batches     | %-50d |\n", train_num_batches);
    printf0("| val_num_batches       | %-50d |\n", val_num_batches);
    printf0("+-----------------------+----------------------------------------------------+\n");

    // pretty print in a table the multi-gpu configuration as well
    printf0("| num_processes         | %-50d |\n", multi_gpu_config.num_processes);
    printf0("+-----------------------+----------------------------------------------------+\n");

    // more prints related to allocations from gpt2_build_from_checkpoint down here to not mess up our table above
    printf0("num_parameters: %zu ==> bytes: %zu\n", model.num_parameters, model.num_parameters_bytes);
    printf0("allocated %d MiB for model parameters\n", (int)round(model.num_parameters_bytes / (1024 * 1024)));

    // set up the Logger & Tokenizer
    Logger logger;
    logger_init(&logger, output_log_file);
    Tokenizer tokenizer;
    tokenizer_init(&tokenizer, "gpt2_tokenizer.bin");

    // some memory for generating samples from the model
    unsigned long long rng_state = 1337;
    int* gen_tokens = (int*)mallocCheck(B * T * sizeof(int));
    floatX* cpu_logits_raw = (floatX*)mallocCheck(model.config.vocab_size * sizeof(floatX));
    float*  cpu_logits = (float*)mallocCheck(model.config.vocab_size * sizeof(float));

    // train
    cudaEvent_t start, end;
    cudaCheck(cudaEventCreate(&start));
    cudaCheck(cudaEventCreate(&end));
    cudaCheck(cudaProfilerStart());
    double total_sum_iteration_time_s = 0.0;
    float ema_tokens_per_second = 0.0f;
    for (int step = 0; step <= train_num_batches; step++) {
        NvtxRange step_range("Train step", step);

        int last_step = step == train_num_batches;

        // once in a while estimate the validation loss
        if (step % val_loss_every == 0 || last_step) {
            NvtxRange validation_range("validation");
            float val_loss = 0.0f;
            dataloader_reset(&val_loader);
            for (int i = 0; i < val_num_batches; i++) {
                dataloader_next_batch(&val_loader);
                gpt2_forward(&model, val_loader.inputs, val_loader.targets, B, T);
                val_loss += model.mean_loss;
            }
            val_loss /= val_num_batches;
            val_loss = multi_gpu_cpu_float_mean(val_loss, &multi_gpu_config);
            printf0("val loss %f\n", val_loss);
            logger_log_val(&logger, step, val_loss);
        }

        // once in a while do model inference to print generated text
        if (multi_gpu_config.process_rank == 0 && (step > 0 && (step % sample_every) == 0 || last_step)) {
            NvtxRange generation_range("generation");
            // fill up gen_tokens with the <|endoftext|> token, which kicks off the generation
            int eot_token = tokenizer.eot_token;
            for(int i = 0; i < B * T; ++i) {
                gen_tokens[i] = eot_token;
            }
            // now sample from the model autoregressively
            printf("generating:\n---\n");
            for (int t = 1; t < genT; t++) {
                NvtxRange generation_range("Generation step", t);
                // note that inference is very wasteful here because for each token
                // we re-calculate the forward pass for all of (B,T) positions from scratch
                // but the inference here is just for sanity checking anyway
                // and we can maybe optimize a bit more later, with careful tests
                gpt2_forward(&model, gen_tokens, NULL, B, T);
                // furthermore, below we're only using b=0 (i.e. the first row) of all B rows
                // we're in principle running B "inference streams" in parallel here
                // only using position 0 because it's a bit faster (copy less probs from GPU -> CPU)
                // get the V-dimensional vector probs[0, t-1, :]
                floatX* logits = model.acts.output + (t - 1) * model.config.padded_vocab_size;
                // move probs back to CPU and sample (note we only move the first vocab_size logits, ignoring the padding)
                cudaCheck(cudaMemcpy(cpu_logits_raw, logits, model.config.vocab_size * sizeof(floatX), cudaMemcpyDeviceToHost));
                // convert to FP32 into cpu_logits (this does nothing useful if floatX == float)
                for (int i = 0; i < model.config.vocab_size; i++) {
                    cpu_logits[i] = (float)cpu_logits_raw[i];
                }

                float coin = random_f32(&rng_state);
                int next_token = sample_softmax(cpu_logits, model.config.vocab_size, coin);
                gen_tokens[t] = next_token;
                // print the generated token, either using the Tokenizer or a fallback
                if (tokenizer.init_ok) {
                    const char* token_str = tokenizer_decode(&tokenizer, next_token);
                    safe_printf(token_str);
                } else {
                    // fall back to printing the token id
                    printf("%d ", next_token);
                }
                fflush(stdout);
            }
            printf("\n---\n");
        }

        // bit confusing: we want to make sure to eval and sample on 0th iteration
        // but also after the very last iteration. so we loop for step <= train_num_batches
        // instead of just < train_num_batches (one extra due to <=), only to do
        // the validation/sampling one last time, and then we break right here as we're done.
        if (last_step) { break; }

        // do a training step
        cudaEventRecord(start);
        if (overfit_single_batch == 0 || (step == 0 && overfit_single_batch == 1)) {
            // if we're overfitting a single batch, we'll only call this at step = 0
            dataloader_next_batch(&train_loader);
        }
        gpt2_forward(&model, train_loader.inputs, train_loader.targets, B, T, false);
        gpt2_zero_grad(&model);
        gpt2_backward(&model);
        if (multi_gpu_config.num_processes > 1) {
            gpt2_multi_gpu_accumulate(&model, &multi_gpu_config);
        }
        gpt2_update(&model, learning_rate, 0.9f, 0.999f, 1e-8f, 0.0f, step+1);

        // todo - move or double-buffer all of this timing logic to avoid idling the GPU at this point!
        cudaEventRecord(end);
        float time_elapsed_ms;
        cudaCheck(cudaEventSynchronize(end)); // wait for the end event to finish to get correct timings
        cudaCheck(cudaEventElapsedTime(&time_elapsed_ms, start, end));

        float tokens_per_second = multi_gpu_config.num_processes * (B * T) / time_elapsed_ms * 1000.0;
        float bias_corrected_ema_tokens_per_second = tokens_per_second; // by default set to non-ema version
        if (step > 0) { // consider the first batch to be a warmup (e.g. cuBLAS/cuDNN initialisation)
            total_sum_iteration_time_s += time_elapsed_ms / 1000.0;
            // smooth out the tok/s with an exponential moving average, and bias correct just like in AdamW
            ema_tokens_per_second = 0.95f * ema_tokens_per_second + 0.05f * tokens_per_second;
            bias_corrected_ema_tokens_per_second = ema_tokens_per_second / (1.0f - powf(0.95f, step));
        }
        float accumulated_loss = multi_gpu_config.num_processes == 1 ? model.mean_loss : model.accumulated_mean_loss;
        printf0("step %4d/%d: train loss %f (acc %f) (%f ms, %0f tok/s)\n",
                step + 1, train_num_batches, model.mean_loss, accumulated_loss,
                time_elapsed_ms, bias_corrected_ema_tokens_per_second);
        logger_log_train(&logger, step, model.mean_loss);

        // disable the profiler after 3 steps of optimization
        if (step == 3) { cudaProfilerStop(); }
    }
    // add a total average, for optimizations that are only mild improvements (excluding 1st batch as warmup)
    printf0("total average iteration time: %f ms\n", total_sum_iteration_time_s / (train_num_batches-1) * 1000);

    // free and destroy everything
    cudaCheck(cudaEventDestroy(end));
    cudaCheck(cudaEventDestroy(start));
    dataloader_free(&train_loader);
    dataloader_free(&val_loader);
    tokenizer_free(&tokenizer);
    free(cpu_logits_raw);
    free(cpu_logits);
    free(gen_tokens);
    logger_free(&logger);
    multi_gpu_config_free(&multi_gpu_config);

    common_free(model);
    return 0;
}
#endif
