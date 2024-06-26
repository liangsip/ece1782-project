#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <chrono>
#include <cuda_runtime.h>
#include <string.h>
#include "bm-utils-cuda.h"

/*
    For benchmarking
    Optimization:
        -v1 Constant Memory: S box
        -v1 Shared Memory: IV and expanded key
        -v1 Pinned Memory: plaintext and ciphertext
        -v2 Coalesced Memory Access: In previous code, each thread is accessing a different block of the plaintext and ciphertext arrays. If the blocks are not contiguous in memory, this could slow down the program. This code rearrange the data so that the blocks accessed by threads in the same warp are contiguous in memory.
        -v3 Divergence Avoidance: 
            -v3.1 aes_ctr_encrypt_kernel(): In the original function, the divergence is caused by the conditional statement if (blockId < numBlocks). This divergence can be avoided by ensuring that the number of threads is a multiple of the number of blocks, which means padding the data to a multiple of the block size.
*/

// Declare fixed data in constant memory
__constant__ unsigned char d_sbox_v3_1[256];

__global__ void aes_ctr_encrypt_kernel_v3_1(unsigned char *plaintext, unsigned char *ciphertext, unsigned char *expandedKey, unsigned char *iv, int numBlocks, int dataSize) {
    // Calculate the unique thread ID within the grid
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    // Create shared memory arrays for the IV and expanded key
    __shared__ unsigned char shared_iv[AES_BLOCK_SIZE];
    __shared__ unsigned char shared_expandedKey[176];

    // Copy the IV and expanded key to shared memory
    if (threadIdx.x < AES_BLOCK_SIZE) {
        shared_iv[threadIdx.x] = iv[threadIdx.x];
    }
    if (threadIdx.x < 176) {
        shared_expandedKey[threadIdx.x] = expandedKey[threadIdx.x];
    }

    // Synchronize to make sure the arrays are fully loaded
    __syncthreads();

    // Define the counter and initialize it with the IV
    unsigned char counter[AES_BLOCK_SIZE];

    // Calculate the number of blocks processed by each thread
    int blocksPerThread = (numBlocks + gridDim.x * blockDim.x - 1) / (gridDim.x * blockDim.x);

    // Process multiple blocks of plaintext/ciphertext
    for (int block = 0; block < blocksPerThread; ++block) {
        int blockId = tid + block * gridDim.x * blockDim.x;

        // Skip the iteration if the blockId is out of range
        if (blockId >= numBlocks) {
            continue;
        }

        memcpy(counter, shared_iv, AES_BLOCK_SIZE);

        // Increment the counter by the block ID
        increment_counter(counter, blockId);

        // Calculate the block size
        int blockSize = (blockId == numBlocks - 1 && dataSize % AES_BLOCK_SIZE != 0) ? dataSize % AES_BLOCK_SIZE : AES_BLOCK_SIZE;

        // Encrypt the counter to get the ciphertext block
        unsigned char ciphertextBlock[AES_BLOCK_SIZE];
        aes_encrypt_block(counter, ciphertextBlock, shared_expandedKey, d_sbox_v3_1);

        // XOR the plaintext with the ciphertext block
        for (int i = 0; i < blockSize; ++i) {
            ciphertext[blockId * AES_BLOCK_SIZE + i] = plaintext[blockId * AES_BLOCK_SIZE + i] ^ ciphertextBlock[i];
        }
    }
}

std::pair<double, double> aes_encrypt_cuda_v3_1(unsigned char *plaintext,
                                              size_t dataSize,
                                              unsigned char *key,
                                              unsigned char *iv,
                                              unsigned char *ciphertext) {
  auto start = std::chrono::high_resolution_clock::now();

  unsigned char *d_plaintext, *d_ciphertext, *d_iv;
  unsigned char *d_expandedKey;

  // Call the host function to expand the key
  unsigned char expandedKey[176];
  KeyExpansionHost(key, expandedKey);

  // Calculate the number of AES blocks needed
  size_t numBlocks = (dataSize + AES_BLOCK_SIZE - 1) / AES_BLOCK_SIZE;

  // Define the size of the grid and the blocks
  dim3 threadsPerBlock(256); // Use a reasonable number of threads per block
  dim3 blocksPerGrid((numBlocks + threadsPerBlock.x - 1) / threadsPerBlock.x);

  // Allocate device memory
  cudaMalloc((void **)&d_iv, AES_BLOCK_SIZE * sizeof(unsigned char));
  cudaMalloc((void **)&d_expandedKey, 176);
  cudaMalloc((void **)&d_plaintext, dataSize * sizeof(unsigned char));
  cudaMalloc((void **)&d_ciphertext, dataSize * sizeof(unsigned char));

  // Copy S-box to device constant memory
  cudaMemcpyToSymbol(d_sbox_v3_1, h_sbox, sizeof(h_sbox));

  // Copy host memory to device
  cudaMemcpy(d_plaintext, plaintext, dataSize * sizeof(unsigned char),
             cudaMemcpyHostToDevice);
  cudaMemcpy(d_iv, iv, AES_BLOCK_SIZE * sizeof(unsigned char),
             cudaMemcpyHostToDevice);
  cudaMemcpy(d_expandedKey, expandedKey, 176, cudaMemcpyHostToDevice);

  // Launch AES-CTR encryption kernel
  auto kernel_start = std::chrono::high_resolution_clock::now();
  aes_ctr_encrypt_kernel_v3_1<<<blocksPerGrid, threadsPerBlock>>>(
      d_plaintext, d_ciphertext, d_expandedKey, d_iv, numBlocks, dataSize);

  // Synchronize device
  cudaDeviceSynchronize();
  auto kernel_stop = std::chrono::high_resolution_clock::now();

  // Copy device ciphertext back to host
  cudaMemcpy(ciphertext, d_ciphertext, dataSize * sizeof(unsigned char),
             cudaMemcpyDeviceToHost);

  // Get the stop time
  auto stop = std::chrono::high_resolution_clock::now();

  // Cleanup
  cudaFree(d_plaintext);
  cudaFree(d_ciphertext);
  cudaFree(d_iv);
  cudaFree(d_expandedKey);

  // Calculate the elapsed time and print
  return std::make_pair(
      std::chrono::duration_cast<std::chrono::microseconds>(stop - start)
          .count(),
      std::chrono::duration_cast<std::chrono::microseconds>(kernel_stop -
                                                            kernel_start)
          .count());
}