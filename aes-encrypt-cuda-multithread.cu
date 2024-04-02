#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <cuda_runtime.h>
#include <string.h>
#include <vector>
#include <thread>
#include <queue>
#include <mutex>
#include <chrono>
#include <condition_variable>
#include "utils-cuda.h"

/*
    DEAD END
    CPU multithreading + GPU stream version
    why: guessing a big transfer is better than multiple small transfer
*/

#define AES_KEY_SIZE 16
#define AES_BLOCK_SIZE 16

__constant__ unsigned char d_sbox[256];
__constant__ unsigned char d_rcon[11];

__device__ unsigned char mul(unsigned char a, unsigned char b) {
    unsigned char p = 0;
    unsigned char high_bit_mask = 0x80;
    unsigned char high_bit = 0;
    unsigned char modulo = 0x1B; /* x^8 + x^4 + x^3 + x + 1 */

    for (int i = 0; i < 8; i++) {
        if (b & 1) {
            p ^= a;
        }

        high_bit = a & high_bit_mask;
        a <<= 1;
        if (high_bit) {
            a ^= modulo;
        }
        b >>= 1;
    }

    return p;
}

void KeyExpansionHost(unsigned char* key, unsigned char* expandedKey) {
    int i = 0;
    while (i < 4) {
        for (int j = 0; j < 4; j++) {
            expandedKey[i * 4 + j] = key[i * 4 + j];
        }
        i++;
    }

    int rconIteration = 1;
    unsigned char temp[4];

    while (i < 44) {
        for (int j = 0; j < 4; j++) {
            temp[j] = expandedKey[(i - 1) * 4 + j];
        }

        if (i % 4 == 0) {
            unsigned char k = temp[0];
            for (int j = 0; j < 3; j++) {
                temp[j] = temp[j + 1];
            }
            temp[3] = k;

            for (int j = 0; j < 4; j++) {
                // Use the host-accessible arrays
                temp[j] = h_sbox[temp[j]] ^ (j == 0 ? h_rcon[rconIteration++] : 0);
            }
        }

        for (int j = 0; j < 4; j++) {
            expandedKey[i * 4 + j] = expandedKey[(i - 4) * 4 + j] ^ temp[j];
        }
        i++;
    }
}

__device__ void SubBytes(unsigned char *state) {
    for (int i = 0; i < 16; ++i) {
        state[i] = d_sbox[state[i]];
    }
}

__device__ void ShiftRows(unsigned char *state) {
    unsigned char tmp[16];

    /* Column 1 */
    tmp[0] = state[0];
    tmp[1] = state[5];
    tmp[2] = state[10];
    tmp[3] = state[15];
    /* Column 2 */
    tmp[4] = state[4];
    tmp[5] = state[9];
    tmp[6] = state[14];
    tmp[7] = state[3];
    /* Column 3 */
    tmp[8] = state[8];
    tmp[9] = state[13];
    tmp[10] = state[2];
    tmp[11] = state[7];
    /* Column 4 */
    tmp[12] = state[12];
    tmp[13] = state[1];
    tmp[14] = state[6];
    tmp[15] = state[11];

    memcpy(state, tmp, 16);
}

__device__ void MixColumns(unsigned char *state) {
    unsigned char tmp[16];

    for (int i = 0; i < 4; ++i) {
        tmp[i*4] = (unsigned char)(mul(0x02, state[i*4]) ^ mul(0x03, state[i*4+1]) ^ state[i*4+2] ^ state[i*4+3]);
        tmp[i*4+1] = (unsigned char)(state[i*4] ^ mul(0x02, state[i*4+1]) ^ mul(0x03, state[i*4+2]) ^ state[i*4+3]);
        tmp[i*4+2] = (unsigned char)(state[i*4] ^ state[i*4+1] ^ mul(0x02, state[i*4+2]) ^ mul(0x03, state[i*4+3]));
        tmp[i*4+3] = (unsigned char)(mul(0x03, state[i*4]) ^ state[i*4+1] ^ state[i*4+2] ^ mul(0x02, state[i*4+3]));
    }

    memcpy(state, tmp, 16);
}

__device__ void AddRoundKey(unsigned char *state, const unsigned char *roundKey) {
    for (int i = 0; i < 16; ++i) {
        state[i] ^= roundKey[i];
    }
}

__device__ void aes_encrypt_block(unsigned char *input, unsigned char *output, unsigned char *expandedKey) {
    unsigned char state[16];

    // Copy the input to the state array
    for (int i = 0; i < 16; ++i) {
        state[i] = input[i];
    }

    // Add the round key to the state
    AddRoundKey(state, expandedKey);

    // Perform 9 rounds of substitutions, shifts, mixes, and round key additions
    for (int round = 1; round < 10; ++round) {
        SubBytes(state);
        ShiftRows(state);
        MixColumns(state);
        AddRoundKey(state, expandedKey + round * 16);
    }

    // Perform the final round (without MixColumns)
    SubBytes(state);
    ShiftRows(state);
    AddRoundKey(state, expandedKey + 10 * 16);

    // Copy the state to the output
    for (int i = 0; i < 16; ++i) {
        output[i] = state[i];
    }
}

__global__ void aes_ctr_encrypt_kernel(unsigned char *plaintext, unsigned char *ciphertext, unsigned char *expandedKey, unsigned char *iv, int numBlocks) {
    // Calculate the global thread ID
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    // Check if the thread is within the number of blocks
    if (tid < numBlocks) {
        // Copy the IV to a local array
        unsigned char localIv[AES_BLOCK_SIZE];
        memcpy(localIv, iv, AES_BLOCK_SIZE);

        // Increment the counter in the local IV
        for (int i = AES_BLOCK_SIZE - 1; i >= 0; --i) {
            unsigned char old = localIv[i];
            localIv[i] += tid;
            if (localIv[i] >= old) break;  // Break if there's no carry
        }

        // Perform the AES encryption
        unsigned char block[AES_BLOCK_SIZE];
        aes_encrypt_block(localIv, block, expandedKey);

        // XOR the plaintext with the encrypted block
        for (int i = 0; i < AES_BLOCK_SIZE; ++i) {
            ciphertext[tid * AES_BLOCK_SIZE + i] = plaintext[tid * AES_BLOCK_SIZE + i] ^ block[i];
        }
    }
}

void processChunk(size_t i, unsigned char** chunks, size_t* chunkSizes, unsigned char* expandedKey, unsigned char* iv, cudaStream_t* streams, unsigned char** d_chunks, unsigned char** d_ciphertexts) {
    cudaStreamCreate(&streams[i]);

    // Allocate memory on the GPU
    cudaMalloc(&d_chunks[i], chunkSizes[i]);
    cudaMalloc(&d_ciphertexts[i], chunkSizes[i]);

    // Copy the chunk to the GPU
    cudaMemcpyAsync(d_chunks[i], chunks[i], chunkSizes[i], cudaMemcpyHostToDevice, streams[i]);

    // Launch the kernel
    dim3 numThreadsPerBlock(256);
    dim3 numBlocksPerGrid(32);
    aes_ctr_encrypt_kernel<<<numBlocksPerGrid, numThreadsPerBlock, 0, streams[i]>>>(d_chunks[i], d_ciphertexts[i], expandedKey, iv, chunkSizes[i] / AES_BLOCK_SIZE);

    // Copy the processed data back to the CPU
    cudaMemcpyAsync(chunks[i], d_ciphertexts[i], chunkSizes[i], cudaMemcpyDeviceToHost, streams[i]);

    // Wait for the copy to finish
    cudaStreamSynchronize(streams[i]);

    // After the copy is finished, write the chunk to the file
    write_encrypted_multithreading(chunks[i], chunkSizes[i], "encrypted.bin");

    cudaStreamDestroy(streams[i]);
    cudaFree(d_chunks[i]);
    cudaFree(d_ciphertexts[i]);
}

std::queue<size_t> workQueue;
std::mutex queueMutex;
std::condition_variable queueCondVar;
// Define the variable at a global scope
bool allChunksProcessed = false;

void workerThread(unsigned char** chunks, size_t* chunkSizes, unsigned char* expandedKey, unsigned char* iv, cudaStream_t* streams, unsigned char** d_chunks, unsigned char** d_ciphertexts) {
    while (true) {
        size_t i;

        // Get a chunk from the queue
        {
            std::unique_lock<std::mutex> lock(queueMutex);

            while (workQueue.empty()) {
                if (allChunksProcessed) return;  // Break the loop if all chunks have been processed
                queueCondVar.wait(lock);
            }

            i = workQueue.front();
            workQueue.pop();
        }

        // Process the chunk
        processChunk(i, chunks, chunkSizes, expandedKey, iv, streams, d_chunks, d_ciphertexts);
    }
}

int main(int argc, char* argv[]) {
    // Check if filename is provided
    if (argc < 2) {
        printf("Usage: %s <filename>\n", argv[0]);
        return 1;
    }

    // Get the start time
    auto start = std::chrono::high_resolution_clock::now();

    // Read the key and IV
    unsigned char key[16];
    unsigned char iv[16];
    read_key_or_iv(key, sizeof(key), "key.txt");
    read_key_or_iv(iv, sizeof(iv), "iv.txt");

    // Call the host function to expand the key
    unsigned char expandedKey[176];
    KeyExpansionHost(key, expandedKey);

    // Preprocess the data into chunks
    unsigned char** chunks = NULL;
    size_t* chunkSizes = NULL;
    size_t numChunks = preprocess(argv[1], AES_BLOCK_SIZE, &chunks, &chunkSizes);

    // Create a pool of CUDA streams
    cudaStream_t* streams = new cudaStream_t[numChunks];
    unsigned char** d_chunks = new unsigned char*[numChunks];
    unsigned char** d_ciphertexts = new unsigned char*[numChunks];

    // Create a pool of worker threads
    std::thread workerThreads[8];
    for (int i = 0; i < 8; i++) {
        workerThreads[i] = std::thread(workerThread, chunks, chunkSizes, expandedKey, iv, streams, d_chunks, d_ciphertexts);
    }

    // Add the chunks to the work queue
    for (size_t i = 0; i < numChunks; i++) {
        {
            std::lock_guard<std::mutex> lock(queueMutex);
            workQueue.push(i);
        }
        
        queueCondVar.notify_one();
    }

    // Set allChunksProcessed to true after all chunks have been added to the work queue
    {
        std::lock_guard<std::mutex> lock(queueMutex);
        allChunksProcessed = true;
    }

    // Notify all waiting threads that all chunks have been processed
    queueCondVar.notify_all();

    // Wait for all threads to finish
    for (int i = 0; i < 8; i++) {
        workerThreads[i].join();
    }

    delete[] chunks;
    delete[] chunkSizes;
    delete[] streams;
    delete[] d_chunks;
    delete[] d_ciphertexts;

    // Get the stop time
    auto stop = std::chrono::high_resolution_clock::now();

    // Calculate the elapsed time and print
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(stop - start);
    std::cout << "Elapsed time: " << duration.count() << " ms\n";

    return 0;
}